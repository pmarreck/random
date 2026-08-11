use core::fmt;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
/// Failures exposed by the deterministic core and entropy adapters.
#[non_exhaustive]
pub enum Error {
	/// The caller supplied an invalid range or distribution parameter.
	InvalidArgument,
	/// The selected byte source could not fill the requested buffer.
	Entropy,
	/// A finite byte source ended before the destination was full.
	EndOfSource,
	/// A nonblocking entropy request would have blocked.
	WouldBlock,
	/// A request would move beyond [`crate::MAX_EXACT_POSITION`].
	PositionOverflow,
	/// Integer-only fixed-point arithmetic exceeded its supported domain.
	Numeric,
	/// The requested operation is not available on this target.
	Unsupported,
}

impl fmt::Display for Error {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		f.write_str(match self {
			Self::InvalidArgument => "invalid argument",
			Self::Entropy => "entropy source failed",
			Self::EndOfSource => "entropy source reached EOF",
			Self::WouldBlock => "entropy source would block",
			Self::PositionOverflow => "DRBG position overflow",
			Self::Numeric => "numeric domain error",
			Self::Unsupported => "operation unsupported on this platform",
		})
	}
}

#[cfg(feature = "std")]
impl std::error::Error for Error {}
