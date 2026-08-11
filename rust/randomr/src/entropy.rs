//! The sole impure library module. Callers explicitly choose a system source
//! or hand this module the path to an entropy device/file.

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use crate::{ByteSource, Error};

/// OS CSPRNG source selected explicitly by the caller.
pub struct SystemEntropy {
	nonblocking: bool,
}

impl SystemEntropy {
	#[must_use]
	/// Construct an OS source; `nonblocking` requests `GRND_NONBLOCK` where supported.
	pub const fn new(nonblocking: bool) -> Self {
		Self { nonblocking }
	}
}

impl ByteSource for SystemEntropy {
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
		fill_system(out, self.nonblocking)
	}
}

/// Exact-read byte source backed by a caller-selected filesystem path.
pub struct PathEntropy {
	file: File,
}

impl PathEntropy {
	/// Open `path` without fallback to any other entropy source.
	pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
		File::open(path).map(|file| Self { file })
	}
}

impl ByteSource for PathEntropy {
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
		self.file
			.read_exact(out)
			.map_err(|error| match error.kind() {
				io::ErrorKind::UnexpectedEof => Error::EndOfSource,
				io::ErrorKind::WouldBlock => Error::WouldBlock,
				_ => Error::Entropy,
			})
	}
}

#[cfg(any(target_os = "linux", target_os = "android"))]
#[derive(Debug, Eq, PartialEq)]
enum KernelFill {
	Complete,
	Unavailable(usize),
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn fill_system(out: &mut [u8], nonblocking: bool) -> Result<(), Error> {
	let flags = if nonblocking { libc::GRND_NONBLOCK } else { 0 };
	match fill_kernel_with(out, flags, |remaining, syscall_flags| {
		// SAFETY: the slice is writable for exactly the length passed to the
		// kernel, and getrandom does not retain its pointer.
		#[allow(unsafe_code)]
		let got = unsafe {
			libc::getrandom(
				remaining.as_mut_ptr().cast(),
				remaining.len(),
				syscall_flags,
			)
		};
		if got >= 0 {
			usize::try_from(got).map_err(|_| libc::EIO)
		} else {
			Err(io::Error::last_os_error()
				.raw_os_error()
				.unwrap_or(libc::EIO))
		}
	})? {
		KernelFill::Complete => Ok(()),
		KernelFill::Unavailable(_) if nonblocking => Err(Error::Unsupported),
		KernelFill::Unavailable(offset) => {
			let mut fallback = PathEntropy::open("/dev/urandom").map_err(|_| Error::Entropy)?;
			fallback
				.fill_exact(&mut out[offset..])
				.map_err(|_| Error::Entropy)
		}
	}
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn fill_kernel_with(
	out: &mut [u8],
	flags: libc::c_uint,
	mut syscall: impl FnMut(&mut [u8], libc::c_uint) -> Result<usize, i32>,
) -> Result<KernelFill, Error> {
	let mut offset = 0;
	while offset < out.len() {
		match syscall(&mut out[offset..], flags) {
			Ok(0) => return Err(Error::Entropy),
			Ok(got) if got <= out.len() - offset => offset += got,
			Ok(_) => return Err(Error::Entropy),
			Err(libc::EINTR) => {}
			Err(libc::ENOSYS) => return Ok(KernelFill::Unavailable(offset)),
			Err(libc::EAGAIN) if flags & libc::GRND_NONBLOCK != 0 => {
				return Err(Error::WouldBlock);
			}
			Err(_) => return Err(Error::Entropy),
		}
	}
	Ok(KernelFill::Complete)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn fill_system(out: &mut [u8], nonblocking: bool) -> Result<(), Error> {
	if nonblocking {
		return Err(Error::Unsupported);
	}
	getrandom::fill(out).map_err(|_| Error::Entropy)
}

#[cfg(all(test, unix))]
mod tests {
	use super::*;

	#[test]
	fn path_entropy_fills_exactly_and_fails_closed_on_eof() {
		let mut zero = PathEntropy::open("/dev/zero").unwrap();
		let mut bytes = [0xa5_u8; 32];
		assert_eq!(zero.fill_exact(&mut bytes), Ok(()));
		assert_eq!(bytes, [0_u8; 32]);

		let mut empty = PathEntropy::open("/dev/null").unwrap();
		assert_eq!(empty.fill_exact(&mut [0_u8; 1]), Err(Error::EndOfSource));
	}

	#[cfg(any(target_os = "linux", target_os = "android"))]
	#[test]
	fn linux_policy_denial_fails_closed_without_fallback() {
		let mut calls = 0;
		let result = fill_kernel_with(&mut [0_u8; 8], 0, |_, _| {
			calls += 1;
			Err(libc::EPERM)
		});
		assert_eq!(result, Err(Error::Entropy));
		assert_eq!(calls, 1);
	}

	#[cfg(any(target_os = "linux", target_os = "android"))]
	#[test]
	fn linux_fallback_is_reserved_for_missing_syscall() {
		let mut calls = 0;
		let mut bytes = [0_u8; 4];
		let result = fill_kernel_with(&mut bytes, 0, |remaining, _| {
			calls += 1;
			match calls {
				1 => Err(libc::EINTR),
				2 => {
					remaining[..2].copy_from_slice(&[0xaa, 0xbb]);
					Ok(2)
				}
				_ => Err(libc::ENOSYS),
			}
		});
		assert_eq!(result, Ok(KernelFill::Unavailable(2)));
		assert_eq!(bytes[..2], [0xaa, 0xbb]);
		assert_eq!(calls, 3);
	}

	#[cfg(any(target_os = "linux", target_os = "android"))]
	#[test]
	fn linux_nonblocking_would_block_is_distinct() {
		let result = fill_kernel_with(&mut [0_u8; 1], libc::GRND_NONBLOCK, |_, _| {
			Err(libc::EAGAIN)
		});
		assert_eq!(result, Err(Error::WouldBlock));
	}
}
