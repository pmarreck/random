mod chart;
mod decimal;
mod options;
mod state;

use std::env;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{self, Command};

use randomr::entropy::{PathEntropy, SystemEntropy};
use randomr::{
	ByteSource, Drbg, Error, Fixed, MAX_EXACT_INTEGER, beta, exponential, log_normal, normal,
	normal_int, poisson, range,
};
use zeroize::{Zeroize, Zeroizing};

use chart::Renderer;
use decimal::{format_fixed, parse_safe_i64};
use options::{Mode, Options, deterministic_invocation, normal_invocation, parse_seed};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const STREAM_CHUNK: usize = 65_536;
const BASE64_ALPHABET: &[u8; 64] =
	b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const OS_PATH_SENTINEL: &str = "\0randomr-os-path-";

enum Source {
	Drbg(Drbg),
	System(SystemEntropy),
	Path(PathEntropy),
}

impl ByteSource for Source {
	fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), Error> {
		match self {
			Self::Drbg(source) => source.fill_exact(out),
			Self::System(source) => source.fill_exact(out),
			Self::Path(source) => source.fill_exact(out),
		}
	}
}

enum Value {
	Integer(i64),
	Fixed(Fixed),
}

fn main() {
	if let Err(message) = run() {
		let encoded = format!(
			"{{\"sv\":1,\"rv\":{},\"error\":{{\"code\":\"usage\",\"message\":{}}},\"notices\":[],\"warnings\":[]}}\n",
			state::quote(VERSION),
			state::quote(&message)
		);
		let _ = io::stderr().lock().write_all(encoded.as_bytes());
		process::exit(1);
	}
}

fn run() -> Result<(), String> {
	let os_args: Vec<OsString> = env::args_os().collect();
	let program_path = os_args
		.first()
		.map(PathBuf::from)
		.unwrap_or_else(|| PathBuf::from("randomr"));
	let (args, os_paths) = normalize_args(&os_args)?;
	let program = program_path.file_name().map_or_else(
		|| "randomr".into(),
		|name| name.to_string_lossy().into_owned(),
	);

	for argument in args.iter().skip(1) {
		match argument.as_str() {
			"--about" | "-a" => {
				print_about(&program)?;
				return Ok(());
			}
			"--help" | "-h" => {
				print_help(&program, &args)?;
				return Ok(());
			}
			"--test" => return run_tests(&program_path),
			_ => {}
		}
	}

	let mut options = options::parse(&args, &program)?;
	restore_os_path(&mut options, &os_paths)?;
	if options.view {
		return print_view(&args, &options);
	}
	let mut notices = Vec::new();
	let mut source = make_source(&mut options)?;
	if options.choose || options.shuffle || options.weighted {
		stdin_operation(&options, &mut source)?;
		return emit_metadata(&options, &source, None, &notices);
	}

	let (start, end, count, show_defaults) = generation_bounds(&options)?;
	if show_defaults {
		notices.push("with the default range 0..99".to_owned());
	}
	if options.binary {
		emit_binary(&options, &mut source, start, end, count)?;
	} else {
		emit_text(&options, &mut source, start, end, count)?;
	}
	emit_metadata(&options, &source, Some((start, end, count)), &notices)
}

fn normalize_args(os_args: &[OsString]) -> Result<(Vec<String>, Vec<PathBuf>), String> {
	let mut text = Vec::with_capacity(os_args.len());
	let mut paths = Vec::new();
	if let Some(program) = os_args.first() {
		text.push(program.to_string_lossy().into_owned());
	}
	let mut index = 1_usize;
	while index < os_args.len() {
		let argument = &os_args[index];
		if argument == "--random-source" {
			text.push("--random-source".to_owned());
			index += 1;
			if index < os_args.len() {
				text.push(normalize_path_argument(&os_args[index], &mut paths));
			}
		} else if let Some(argument) = argument.to_str() {
			text.push(argument.to_owned());
		} else if let Some(path) = attached_random_source(argument) {
			let sentinel = normalize_path_argument(path.as_os_str(), &mut paths);
			text.push(format!("--random-source={sentinel}"));
		} else {
			return Err(
				"arguments other than --random-source paths must be valid UTF-8".to_owned(),
			);
		}
		index += 1;
	}
	Ok((text, paths))
}

fn normalize_path_argument(path: &OsStr, paths: &mut Vec<PathBuf>) -> String {
	if let Some(path) = path.to_str() {
		path.to_owned()
	} else {
		let index = paths.len();
		paths.push(PathBuf::from(path));
		format!("{OS_PATH_SENTINEL}{index}")
	}
}

fn restore_os_path(options: &mut Options, paths: &[PathBuf]) -> Result<(), String> {
	let Some(path) = &options.random_source else {
		return Ok(());
	};
	let Some(text) = path.to_str() else {
		return Ok(());
	};
	let Some(index) = text.strip_prefix(OS_PATH_SENTINEL) else {
		return Ok(());
	};
	let index = index
		.parse::<usize>()
		.map_err(|_| "internal random-source path marker is invalid".to_owned())?;
	options.random_source = Some(
		paths
			.get(index)
			.ok_or_else(|| "internal random-source path marker is missing".to_owned())?
			.clone(),
	);
	Ok(())
}

#[cfg(unix)]
fn attached_random_source(argument: &OsStr) -> Option<PathBuf> {
	use std::os::unix::ffi::{OsStrExt, OsStringExt};

	argument
		.as_bytes()
		.strip_prefix(b"--random-source=")
		.map(|path| PathBuf::from(OsString::from_vec(path.to_vec())))
}

#[cfg(not(unix))]
fn attached_random_source(_argument: &OsStr) -> Option<PathBuf> {
	None
}

fn make_source(options: &mut Options) -> Result<Source, String> {
	if options.deterministic {
		let mut seed = Zeroizing::new([0_u8; 32]);
		if let Some(provided) = options.seed.as_ref() {
			seed.copy_from_slice(provided);
		} else if let Some(value) = env::var_os("DRANDOMR_SEED").filter(|value| !value.is_empty()) {
			let text = value.to_string_lossy();
			let mut parsed = parse_seed(&text).ok_or_else(|| {
                format!(
                    "DRANDOMR_SEED must be an unsigned decimal or 0x-prefixed hexadecimal integer smaller than 2^256, got: {text}"
                )
			})?;
			seed.copy_from_slice(&parsed);
			parsed.zeroize();
		} else {
			let mut entropy = entropy_source(options)?;
			entropy.fill_exact(&mut *seed).map_err(entropy_error)?;
		}
		let mut drbg = Drbg::new(&seed);
		if let Some(position) = options.state_position {
			drbg.seek(position).map_err(core_error)?;
		}
		options.seed = Some(*seed);
		Ok(Source::Drbg(drbg))
	} else {
		entropy_source(options)
	}
}

fn emit_metadata(
	options: &Options,
	source: &Source,
	bounds: Option<(i64, i64, u64)>,
	notices: &[String],
) -> Result<(), String> {
	let mut output = String::new();
	if let (Some(seed), Source::Drbg(drbg)) = (options.seed.as_ref(), source) {
		use std::fmt::Write as _;
		write!(
			output,
			"{{\"sv\":1,\"rv\":{},\"seed\":\"0x",
			state::quote(VERSION)
		)
		.map_err(|_| "state formatting failed".to_owned())?;
		for byte in seed {
			write!(output, "{byte:02x}").map_err(|_| "state formatting failed".to_owned())?;
		}
		write!(
			output,
			"\",\"next_pos\":{},\"args\":{}",
			state::quote(&drbg.position().to_string()),
			canonical_args(options, bounds)
		)
		.map_err(|_| "state formatting failed".to_owned())?;
	} else if notices.is_empty() {
		return Ok(());
	} else {
		output.push_str(&format!("{{\"sv\":1,\"rv\":{}", state::quote(VERSION)));
	}
	output.push_str(",\"notices\":[");
	for (index, notice) in notices.iter().enumerate() {
		if index > 0 {
			output.push(',');
		}
		output.push_str(&state::quote(notice));
	}
	output.push_str("],\"warnings\":[]}\n");
	io::stderr()
		.lock()
		.write_all(output.as_bytes())
		.map_err(|_| "stderr write failed".to_owned())
}

fn canonical_args(options: &Options, bounds: Option<(i64, i64, u64)>) -> String {
	let mut fields = Vec::new();
	if options.choose || options.shuffle || options.weighted {
		push_string(
			&mut fields,
			"operation",
			if options.choose {
				"choose"
			} else if options.shuffle {
				"shuffle"
			} else {
				"weighted"
			},
		);
		push_string(&mut fields, "delimiter", &options.delimiter);
		return format!("{{{}}}", fields.join(","));
	}
	let (start, end, count) = bounds.expect("generation bounds are present");
	push_string(
		&mut fields,
		"distribution",
		match options.mode {
			Mode::Uniform => "uniform",
			Mode::Normal => "normal",
			Mode::Exponential => "exponential",
			Mode::Poisson => "poisson",
			Mode::LogNormal => "log-normal",
			Mode::Beta => "beta",
		},
	);
	let range_scaled = matches!(options.mode, Mode::Uniform | Mode::Normal)
		&& !(options.mode == Mode::Normal && (options.mean.is_some() || options.stddev.is_some()));
	if range_scaled {
		push_string(&mut fields, "range", &format!("{start}..{end}"));
	}
	push_string(&mut fields, "count", &count.to_string());
	match options.mode {
		Mode::Normal if !range_scaled => {
			push_string(
				&mut fields,
				"mean",
				options.mean.as_ref().map_or("0", |value| &value.1),
			);
			push_string(
				&mut fields,
				"stddev",
				options.stddev.as_ref().map_or("1", |value| &value.1),
			);
		}
		Mode::Exponential => push_string(
			&mut fields,
			"rate",
			options.rate.as_ref().map_or("1", |value| &value.1),
		),
		Mode::Poisson => push_string(
			&mut fields,
			"lambda",
			options
				.lambda
				.as_ref()
				.or(options.mean.as_ref())
				.map_or("1", |value| &value.1),
		),
		Mode::LogNormal => {
			push_string(
				&mut fields,
				"mean",
				options.mean.as_ref().map_or("0", |value| &value.1),
			);
			push_string(
				&mut fields,
				"stddev",
				options.stddev.as_ref().map_or("1", |value| &value.1),
			);
		}
		Mode::Beta => {
			push_string(
				&mut fields,
				"alpha",
				options.alpha.as_ref().map_or("2", |value| &value.1),
			);
			push_string(
				&mut fields,
				"beta",
				options.beta.as_ref().map_or("2", |value| &value.1),
			);
		}
		Mode::Uniform | Mode::Normal => {}
	}
	if matches!(
		options.mode,
		Mode::Exponential | Mode::LogNormal | Mode::Beta
	) {
		push_string(&mut fields, "precision", &options.precision.to_string());
	}
	if options.binary {
		fields.push("\"binary\":true".to_owned());
	}
	push_string(
		&mut fields,
		"encoding",
		if options.binary {
			if options.base64 {
				"base64"
			} else if options.hex {
				"binary-hex"
			} else {
				"raw"
			}
		} else if options.hex {
			"hex"
		} else {
			"text"
		},
	);
	if !options.binary {
		push_string(&mut fields, "delimiter", &options.delimiter);
	}
	format!("{{{}}}", fields.join(","))
}

fn push_string(fields: &mut Vec<String>, key: &str, value: &str) {
	fields.push(format!("{}:{}", state::quote(key), state::quote(value)));
}

fn entropy_source(options: &Options) -> Result<Source, String> {
	if let Some(path) = &options.random_source {
		PathEntropy::open(path)
			.map(Source::Path)
			.map_err(|error| format!("entropy could not open {}: {error}", path.display()))
	} else {
		Ok(Source::System(SystemEntropy::new(options.no_wait)))
	}
}

fn generation_bounds(options: &Options) -> Result<(i64, i64, u64, bool), String> {
	let (start, end) = options
		.range
		.unwrap_or(if options.binary { (0, 255) } else { (0, 99) });
	let count = u64::try_from(
		options
			.count
			.unwrap_or(if options.binary { 1024 } else { 1 }),
	)
	.map_err(|_| "invalid count".to_owned())?;
	if options.binary {
		if start < 0 {
			return Err("start value must be >= 0 for binary output".to_owned());
		}
		if end > 255 {
			return Err("end value must be <= 255 for binary output".to_owned());
		}
	}
	if matches!(options.mode, Mode::Uniform | Mode::Normal) {
		if start > end {
			return Err("start value must be less than or equal to end value".to_owned());
		}
		if i128::from(end) - i128::from(start) >= i128::from(MAX_EXACT_INTEGER) {
			return Err("an inclusive integer range may contain at most 2^53 values".to_owned());
		}
	}
	let range_scaled = matches!(options.mode, Mode::Uniform | Mode::Normal)
		&& !(options.mode == Mode::Normal && (options.mean.is_some() || options.stddev.is_some()));
	Ok((
		start,
		end,
		count,
		!options.binary && options.range.is_none() && range_scaled,
	))
}

fn generate(options: &Options, source: &mut Source, start: i64, end: i64) -> Result<Value, String> {
	let one = Fixed::from_i64(1);
	let two = Fixed::from_i64(2);
	let result = match options.mode {
		Mode::Uniform => Value::Integer(range(source, start, end).map_err(core_error)?),
		Mode::Normal if options.mean.is_none() && options.stddev.is_none() => {
			Value::Integer(normal_int(source, start, end).map_err(core_error)?)
		}
		Mode::Normal => {
			let value = normal(
				source,
				options.mean.as_ref().map_or(Fixed::ZERO, |value| value.0),
				options.stddev.as_ref().map_or(one, |value| value.0),
			)
			.map_err(core_error)?;
			Value::Integer(value.round_to_i64().map_err(core_error)?)
		}
		Mode::Exponential => Value::Fixed(
			exponential(source, options.rate.as_ref().map_or(one, |value| value.0))
				.map_err(core_error)?,
		),
		Mode::Poisson => Value::Integer(
			poisson(
				source,
				options
					.lambda
					.as_ref()
					.or(options.mean.as_ref())
					.map_or(one, |value| value.0),
			)
			.map_err(core_error)?,
		),
		Mode::LogNormal => Value::Fixed(
			log_normal(
				source,
				options.mean.as_ref().map_or(Fixed::ZERO, |value| value.0),
				options.stddev.as_ref().map_or(one, |value| value.0),
			)
			.map_err(core_error)?,
		),
		Mode::Beta => Value::Fixed(
			beta(
				source,
				options.alpha.as_ref().map_or(two, |value| value.0),
				options.beta.as_ref().map_or(two, |value| value.0),
			)
			.map_err(core_error)?,
		),
	};
	Ok(result)
}

fn core_error(error: Error) -> String {
	format!("RNG core failed: {error}")
}

fn entropy_error(error: Error) -> String {
	match error {
		Error::Unsupported => "--no-wait is unsupported by this entropy source".to_owned(),
		Error::Entropy => "entropy source failed".to_owned(),
		Error::EndOfSource => "entropy source reached EOF before filling the request".to_owned(),
		Error::WouldBlock => "entropy source would block".to_owned(),
		other => format!("entropy source failed: {other}"),
	}
}

fn value_byte(value: Value) -> u8 {
	let integer = match value {
		Value::Integer(integer) => integer,
		Value::Fixed(fixed) => fixed.to_i64_trunc(),
	};
	integer.rem_euclid(256) as u8
}

fn emit_text(
	options: &Options,
	source: &mut Source,
	start: i64,
	end: i64,
	count: u64,
) -> Result<(), String> {
	let stdout = io::stdout();
	let mut output = stdout.lock();
	for index in 0..count {
		if index > 0 && options.delimiter != "\n" {
			output
				.write_all(options.delimiter.as_bytes())
				.map_err(|_| "stdout write failed".to_owned())?;
		}
		let value = generate(options, source, start, end)?;
		let text = match value {
			Value::Integer(integer) if options.hex => format!("{integer:x}"),
			Value::Integer(integer) => integer.to_string(),
			Value::Fixed(fixed) => format_fixed(fixed, options.precision)?.to_owned(),
		};
		output
			.write_all(text.as_bytes())
			.map_err(|_| "stdout write failed".to_owned())?;
		if options.delimiter == "\n" {
			output
				.write_all(b"\n")
				.map_err(|_| "stdout write failed".to_owned())?;
		}
	}
	if options.delimiter != "\n" {
		output
			.write_all(b"\n")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	output.flush().map_err(|_| "stdout write failed".to_owned())
}

fn emit_binary(
	options: &Options,
	source: &mut Source,
	start: i64,
	end: i64,
	count: u64,
) -> Result<(), String> {
	let stdout = io::stdout();
	let mut output = stdout.lock();
	let buffer_len = usize::try_from(count.min(STREAM_CHUNK as u64))
		.map_err(|_| "output count is too large".to_owned())?;
	let mut bytes = vec![0_u8; buffer_len];
	let mut encoded = Vec::with_capacity(STREAM_CHUNK * 2);
	let mut carry = [0_u8; 2];
	let mut carry_len = 0_usize;
	let mut remaining = count;
	while remaining > 0 {
		let chunk = usize::try_from(remaining.min(STREAM_CHUNK as u64))
			.map_err(|_| "output count is too large".to_owned())?;
		let bytes = &mut bytes[..chunk];
		if options.mode == Mode::Uniform && start == 0 && end == 255 {
			source.fill_exact(bytes).map_err(entropy_error)?;
		} else {
			for byte in &mut *bytes {
				*byte = value_byte(generate(options, source, start, end)?);
			}
		}
		if options.base64 {
			write_base64_chunk(&mut output, bytes, &mut carry, &mut carry_len, &mut encoded)?;
		} else if options.hex {
			encoded.clear();
			for &byte in &*bytes {
				encoded.push(b"0123456789abcdef"[usize::from(byte >> 4)]);
				encoded.push(b"0123456789abcdef"[usize::from(byte & 15)]);
			}
			output
				.write_all(&encoded)
				.map_err(|_| "stdout write failed".to_owned())?;
		} else {
			output
				.write_all(bytes)
				.map_err(|_| "stdout write failed".to_owned())?;
		}
		remaining -= chunk as u64;
	}
	if options.base64 {
		finish_base64(&mut output, &carry, carry_len)?;
		output
			.write_all(b"\n")
			.map_err(|_| "stdout write failed".to_owned())?;
	} else if options.hex {
		output
			.write_all(b"\n")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	output.flush().map_err(|_| "stdout write failed".to_owned())
}

fn push_base64_quad(encoded: &mut Vec<u8>, bytes: [u8; 3]) {
	let word = (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2]);
	encoded.push(BASE64_ALPHABET[((word >> 18) & 63) as usize]);
	encoded.push(BASE64_ALPHABET[((word >> 12) & 63) as usize]);
	encoded.push(BASE64_ALPHABET[((word >> 6) & 63) as usize]);
	encoded.push(BASE64_ALPHABET[(word & 63) as usize]);
}

fn write_base64_chunk(
	output: &mut impl Write,
	bytes: &[u8],
	carry: &mut [u8; 2],
	carry_len: &mut usize,
	encoded: &mut Vec<u8>,
) -> Result<(), String> {
	encoded.clear();
	let mut index = 0_usize;
	if *carry_len > 0 {
		let needed = 3 - *carry_len;
		if bytes.len() < needed {
			carry[*carry_len..*carry_len + bytes.len()].copy_from_slice(bytes);
			*carry_len += bytes.len();
			return Ok(());
		}
		let mut triple = [0_u8; 3];
		triple[..*carry_len].copy_from_slice(&carry[..*carry_len]);
		triple[*carry_len..].copy_from_slice(&bytes[..needed]);
		push_base64_quad(encoded, triple);
		index = needed;
		*carry_len = 0;
	}
	while index + 3 <= bytes.len() {
		push_base64_quad(encoded, [bytes[index], bytes[index + 1], bytes[index + 2]]);
		index += 3;
	}
	*carry_len = bytes.len() - index;
	carry[..*carry_len].copy_from_slice(&bytes[index..]);
	output
		.write_all(encoded)
		.map_err(|_| "stdout write failed".to_owned())
}

fn finish_base64(output: &mut impl Write, carry: &[u8; 2], carry_len: usize) -> Result<(), String> {
	let mut encoded = [b'='; 4];
	if carry_len > 0 {
		let word = (u32::from(carry[0]) << 16)
			| if carry_len == 2 {
				u32::from(carry[1]) << 8
			} else {
				0
			};
		encoded[0] = BASE64_ALPHABET[((word >> 18) & 63) as usize];
		encoded[1] = BASE64_ALPHABET[((word >> 12) & 63) as usize];
		if carry_len == 2 {
			encoded[2] = BASE64_ALPHABET[((word >> 6) & 63) as usize];
		}
		output
			.write_all(&encoded)
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	Ok(())
}

fn trim_ascii(mut input: &[u8]) -> &[u8] {
	while input.first().is_some_and(u8::is_ascii_whitespace) {
		input = &input[1..];
	}
	while input.last().is_some_and(u8::is_ascii_whitespace) {
		input = &input[..input.len() - 1];
	}
	input
}

fn read_items(delimiter: &str) -> Result<Vec<Vec<u8>>, String> {
	let mut input = Vec::new();
	io::stdin()
		.read_to_end(&mut input)
		.map_err(|_| "could not read stdin".to_owned())?;
	let content = trim_ascii(&input);
	if content.is_empty() {
		return Ok(Vec::new());
	}
	let mut items = Vec::new();
	if delimiter == "\n" {
		for item in content.split(|byte| *byte == b'\n') {
			let item = item.strip_suffix(b"\r").unwrap_or(item);
			if !item.is_empty() {
				items.push(item.to_vec());
			}
		}
	} else {
		let delimiters = delimiter.as_bytes();
		for item in content.split(|byte| delimiters.contains(byte)) {
			let item = trim_ascii(item);
			if !item.is_empty() {
				items.push(item.to_vec());
			}
		}
	}
	Ok(items)
}

fn stdin_operation(options: &Options, source: &mut Source) -> Result<(), String> {
	let mut items = read_items(&options.delimiter)?;
	if items.is_empty() {
		return Err(if options.choose {
			"no items to choose from"
		} else if options.shuffle {
			"no items to shuffle"
		} else {
			"no items for weighted selection"
		}
		.to_owned());
	}
	let stdout = io::stdout();
	let mut output = stdout.lock();
	if options.choose {
		let index = range(source, 1, items.len() as i64).map_err(core_error)? as usize - 1;
		output
			.write_all(&items[index])
			.and_then(|()| output.write_all(b"\n"))
			.map_err(|_| "stdout write failed".to_owned())?;
	} else if options.shuffle {
		for count in (2..=items.len()).rev() {
			let index = range(source, 1, count as i64).map_err(core_error)? as usize - 1;
			items.swap(count - 1, index);
		}
		for item in items {
			output
				.write_all(&item)
				.and_then(|()| output.write_all(b"\n"))
				.map_err(|_| "stdout write failed".to_owned())?;
		}
	} else {
		let mut weighted = Vec::with_capacity(items.len());
		let mut total = 0_i64;
		for item in items {
			let Some(separator) = item.iter().rposition(|byte| *byte == b':') else {
				return Err(format!(
					"weighted item must be in format 'value:weight', got: {}",
					String::from_utf8_lossy(&item)
				));
			};
			let (name, weight_with_colon) = item.split_at(separator);
			let weight = &weight_with_colon[1..];
			if name.is_empty() || weight.is_empty() || !weight.iter().all(u8::is_ascii_digit) {
				return Err(format!(
					"weighted item must be in format 'value:weight', got: {}",
					String::from_utf8_lossy(&item)
				));
			}
			let weight_text = core::str::from_utf8(weight)
				.map_err(|_| "weighted item weight must contain ASCII digits".to_owned())?;
			let weight = parse_safe_i64(weight_text).ok_or_else(|| {
				format!(
					"weighted item weight is out of range (must be a whole number no larger than 2^53): {}",
					String::from_utf8_lossy(&item)
				)
			})?;
			total = total
				.checked_add(weight)
				.filter(|value| *value <= MAX_EXACT_INTEGER)
				.ok_or_else(|| {
					"total weighted-item weight must be no larger than 2^53".to_owned()
				})?;
			weighted.push((name.to_vec(), weight));
		}
		if total == 0 {
			return Err("total weighted-item weight must be positive".to_owned());
		}
		let pick = range(source, 1, total).map_err(core_error)?;
		let mut cumulative = 0_i64;
		for (item, weight) in weighted {
			cumulative += weight;
			if pick <= cumulative {
				output
					.write_all(&item)
					.and_then(|()| output.write_all(b"\n"))
					.map_err(|_| "stdout write failed".to_owned())?;
				break;
			}
		}
	}
	output.flush().map_err(|_| "stdout write failed".to_owned())
}

fn print_about(program: &str) -> Result<(), String> {
	let description = if normal_invocation(program) {
		"CSPRNG for normal variates with OS entropy or cross-platform-identical deterministic streams"
	} else if deterministic_invocation(program) {
		"Cross-platform-identical deterministic CSPRNG using a seeded BLAKE3 keyed XOF"
	} else {
		"CSPRNG with OS entropy, cross-platform-identical deterministic streams, and alternate distributions"
	};
	let text = format!(
		"{program} v{VERSION} ({}/{}): {description}",
		platform_name(),
		architecture_name()
	);
	writeln!(io::stdout().lock(), "{text}").map_err(|_| "stdout write failed".to_owned())
}

fn platform_name() -> &'static str {
	if cfg!(target_os = "windows") {
		"Windows"
	} else if cfg!(target_os = "macos") {
		"OSX"
	} else if cfg!(target_os = "linux") {
		"Linux"
	} else if cfg!(target_os = "freebsd") {
		"FreeBSD"
	} else if cfg!(target_os = "netbsd") {
		"NetBSD"
	} else if cfg!(target_os = "openbsd") {
		"OpenBSD"
	} else if cfg!(target_os = "dragonfly") {
		"DragonFlyBSD"
	} else if cfg!(target_os = "solaris") {
		"Solaris"
	} else if cfg!(target_os = "illumos") {
		"illumos"
	} else if cfg!(target_os = "wasi") {
		"WASI"
	} else {
		"Unknown"
	}
}

fn architecture_name() -> &'static str {
	if cfg!(target_arch = "aarch64") {
		"arm64"
	} else if cfg!(target_arch = "x86_64") {
		"x64"
	} else if cfg!(target_arch = "x86") {
		"x86"
	} else {
		"unknown"
	}
}

fn selected_help_mode(args: &[String], program: &str) -> Mode {
	let mut selected = if normal_invocation(program) {
		Mode::Normal
	} else {
		Mode::Uniform
	};
	for argument in args.iter().skip(1) {
		let candidate = match argument.as_str() {
			"--normalized" | "-n" => Some(Mode::Normal),
			"--exponential" => Some(Mode::Exponential),
			"--poisson" => Some(Mode::Poisson),
			"--log-normal" => Some(Mode::LogNormal),
			"--beta" => Some(Mode::Beta),
			_ if argument.starts_with("--beta=") => Some(Mode::Beta),
			_ => None,
		};
		if let Some(candidate) = candidate {
			if selected != Mode::Uniform && selected != candidate {
				return Mode::Uniform;
			}
			selected = candidate;
		}
	}
	selected
}

fn print_help(program: &str, args: &[String]) -> Result<(), String> {
	let mode = selected_help_mode(args, program);
	let text = format!(
		"Usage: {program} [options] [dN|M-N|M..N|M...N]\n\
                echo 'items' | {program} --choose\n\
                echo 'items' | {program} --shuffle\n\n\
         Cryptographically secure random generator with alternate distributions.\n\
         Seeded mode provides cross-platform-identical deterministic streams.\n\
         True-random mode uses fresh OS CSPRNG entropy; deterministic mode uses\n\
         a seeded BLAKE3 keyed XOF. A public seed is reproducible, not secret.\n\
         A positional dN rolls an N-sided die by selecting uniformly from 1..N.\n\n\
         Distributions (mutually exclusive):\n\
           (default)           Uniform distribution\n\
           -n, --normalized    Normal (Gaussian) via Box-Muller\n\
               --exponential   Exponential distribution (use --rate)\n\
               --poisson       Poisson distribution (use --lambda or --mean)\n\
               --log-normal    Log-normal distribution\n\
               --beta[=B]      Beta distribution; optional B replaces default beta 2\n\n\
         Stdin operations:\n\
               --choose        Pick one random item from stdin\n\
               --shuffle       Shuffle all items from stdin\n\
               --weighted      Pick from weighted stdin (format: value:weight)\n\n\
         Options:\n\
           -a, --about         Show a short description\n\
           -b, --binaryoutput  Output binary bytes\n\
           -c, --count N       Output N numbers (default: 1, or 1024 with -b)\n\
           -d, --deterministic Use the cross-platform-identical BLAKE3 keyed XOF\n\
               --true-random   Force fresh OS/source CSPRNG entropy; ignore DRANDOMR_SEED\n\
               --delimiter S   Set delimiter for output/input (default: newline)\n\
               --precision N   Truncate fractional output to 0..18 places (default: 18)\n\
               --truncate N    Alias for --precision\n\
           -h, --help          Show this help message\n\
               --hex           Output as hexadecimal\n\
               --base64        Output as base64 (for binary)\n\
               --seed N|0xHEX  Set unsigned 256-bit integer seed (implies -d)\n\
               --state [JSON|-] Resume from JSON; omitted value or '-' reads stdin\n\
               --resume [JSON|-] Alias for --state\n\
               --random-source PATH  Read entropy from PATH instead of the OS\n\
               --no-wait       Use nonblocking getrandom; fail if the pool is not ready\n\
               --kitty         Force Kitty graphics for a distribution help chart\n\
               --sixel         Force Sixel graphics for a distribution help chart\n\
               --utf8           Force the UTF-8 Braille distribution chart\n\
               --utf8-graphics  Long alias for --utf8\n\
               --view          Show only the selected distribution with supplied parameters\n\
               --mean M        Set mean for normal/log-normal; Poisson lambda alias\n\
               --stddev S      Set stddev for normal/log-normal\n\
               --rate R        Set exponential rate\n\
               --lambda L      Set Poisson lambda (clearer alias for --mean)\n\
               --alpha A       Set alpha for beta distribution\n\
               --test          Run the test suite\n\n\
         Symlink behavior:\n\
           'nrandomr' -> implies --normalized\n\
           'drandomr' -> implies --deterministic\n\n\
         Environment variables:\n\
           DRANDOMR_SEED     Unsigned decimal or 0x-prefixed seed (implies -d)\n\
           RANDOMZ_CHART_TYPE  utf8, kitty, or sixel; command-line flags override it\n\n\
         Deterministic mode never persists state. A seed starts at stream position\n\
         zero; --state/--resume continues at its exact BLAKE3 byte position.\n\
         Deterministic success metadata and all diagnostics are JSON on stderr.\n\
         Without a seed, deterministic mode obtains 32 bytes from OS entropy.\n\
         Seeded output, including alternate distributions, is byte-identical\n\
         across supported operating systems and CPU architectures.\n"
	);
	io::stdout()
		.lock()
		.write_all(text.as_bytes())
		.map_err(|_| "stdout write failed".to_owned())?;
	if mode != Mode::Uniform {
		print_help_chart(args, mode)?;
	}
	Ok(())
}

fn print_help_chart(args: &[String], mode: Mode) -> Result<(), String> {
	let key = match mode {
		Mode::Normal => "normal",
		Mode::Exponential => "exponential",
		Mode::Poisson => "poisson",
		Mode::LogNormal => "log_normal",
		Mode::Beta => "beta",
		Mode::Uniform => unreachable!(),
	};
	let embedded = chart::embedded(key).ok_or_else(|| "embedded chart is absent".to_owned())?;
	let renderer = Renderer::select(args)?;
	let stdout = io::stdout();
	let mut output = stdout.lock();
	writeln!(
		output,
		"\nDistribution: {}\n{}\n",
		embedded.title, embedded.parameters
	)
	.map_err(|_| "stdout write failed".to_owned())?;
	chart::render_embedded(embedded, renderer, &mut output)?;
	writeln!(output, "{}", embedded.axis).map_err(|_| "stdout write failed".to_owned())
}

fn print_view(args: &[String], options: &Options) -> Result<(), String> {
	let zero = Fixed::ZERO;
	let one = Fixed::from_i64(1);
	let two = Fixed::from_i64(2);
	let (title, axis, first, second, parameters) = match options.mode {
		Mode::Normal => (
			"Normal (Gaussian)",
			"Horizontal axis: mean +/- 4 standard deviations; vertical axis: relative probability density.",
			options.mean.as_ref().map_or(zero, |value| value.0),
			options.stddev.as_ref().map_or(one, |value| value.0),
			format!(
				"Parameters: mean={}, stddev={}.",
				options.mean.as_ref().map_or("0", |value| value.1.as_str()),
				options
					.stddev
					.as_ref()
					.map_or("1", |value| value.1.as_str())
			),
		),
		Mode::Exponential => (
			"Exponential",
			"Horizontal axis: 0 to 6/rate; vertical axis: relative probability density.",
			options.rate.as_ref().map_or(one, |value| value.0),
			zero,
			format!(
				"Parameters: rate={}.",
				options.rate.as_ref().map_or("1", |value| value.1.as_str())
			),
		),
		Mode::Poisson => {
			let parameter = options.lambda.as_ref().or(options.mean.as_ref());
			(
				"Poisson",
				"Horizontal axis: lambda +/- 6*sqrt(lambda), clipped at zero; vertical axis: probability mass.",
				parameter.map_or(one, |value| value.0),
				zero,
				format!(
					"Parameters: lambda={}.",
					parameter.map_or("1", |value| value.1.as_str())
				),
			)
		}
		Mode::LogNormal => (
			"Log-normal",
			"Horizontal axis: 0 to exp(mean + min(1.625*stddev, 20)); vertical axis: relative probability density.",
			options.mean.as_ref().map_or(zero, |value| value.0),
			options.stddev.as_ref().map_or(one, |value| value.0),
			format!(
				"Parameters: mean={}, stddev={}.",
				options.mean.as_ref().map_or("0", |value| value.1.as_str()),
				options
					.stddev
					.as_ref()
					.map_or("1", |value| value.1.as_str())
			),
		),
		Mode::Beta => (
			"Beta",
			"Horizontal axis: value from 0 to 1; vertical axis: relative probability density.",
			options.alpha.as_ref().map_or(two, |value| value.0),
			options.beta.as_ref().map_or(two, |value| value.0),
			format!(
				"Parameters: alpha={}, beta={}.",
				options.alpha.as_ref().map_or("2", |value| value.1.as_str()),
				options.beta.as_ref().map_or("2", |value| value.1.as_str())
			),
		),
		Mode::Uniform => {
			return Err("--view requires exactly one alternate distribution".to_owned());
		}
	};
	let renderer = Renderer::select(args)?;
	let stdout = io::stdout();
	let mut output = stdout.lock();
	writeln!(output, "Distribution: {title}\n{parameters}\n")
		.map_err(|_| "stdout write failed".to_owned())?;
	chart::render(
		distribution(options.mode),
		first,
		second,
		renderer,
		&mut output,
	)?;
	writeln!(output, "{axis}").map_err(|_| "stdout write failed".to_owned())
}

fn distribution(mode: Mode) -> randomr::Distribution {
	match mode {
		Mode::Normal => randomr::Distribution::Normal,
		Mode::Exponential => randomr::Distribution::Exponential,
		Mode::Poisson => randomr::Distribution::Poisson,
		Mode::LogNormal => randomr::Distribution::LogNormal,
		Mode::Beta => randomr::Distribution::Beta,
		Mode::Uniform => unreachable!(),
	}
}

fn run_tests(program_path: &Path) -> Result<(), String> {
	if env::var_os("RANDOM_TEST_DEPTH").is_some_and(|depth| depth == "1") {
		return Ok(());
	}
	let test = env::var_os("RANDOM_TEST_FILE")
		.map(std::path::PathBuf::from)
		.or_else(|| {
			let path = program_path;
			[
				path.parent()?.join("../../tests/random_test"),
				path.parent()?.join("../tests/random_test"),
				std::path::PathBuf::from("tests/random_test"),
			]
			.into_iter()
			.find(|candidate| candidate.is_file())
		})
		.ok_or_else(|| "could not locate test suite".to_owned())?;
	// The shared contract is intentionally a Bash suite on every platform.
	// Invoke Bash explicitly so installed packages do not depend on
	// `/usr/bin/env` existing merely to resolve the suite's shebang (notably,
	// the Nix build sandbox has no `/usr/bin`).
	let mut command = Command::new(test_bash_command());
	command.arg(&test);
	let status = command
		.env("FAST", "1")
		.env("RANDOM_TEST_DEPTH", "0")
		.env("RANDOM_TEST_CLI", program_path)
		.env("RANDOM_TEST_CLI_KIND", "rust")
		.status()
		.map_err(|error| format!("could not run test suite: {error}"))?;
	if status.success() {
		Ok(())
	} else {
		process::exit(status.code().unwrap_or(1));
	}
}

fn test_bash_command() -> OsString {
	let candidates = test_bash_candidates();
	select_test_bash(env::var_os("RANDOM_TEST_BASH"), candidates, |candidate| {
		candidate.is_file()
	})
}

fn select_test_bash(
	explicit: Option<OsString>,
	candidates: impl IntoIterator<Item = PathBuf>,
	mut is_file: impl FnMut(&Path) -> bool,
) -> OsString {
	if let Some(explicit) = explicit {
		return explicit;
	}
	candidates
		.into_iter()
		.find(|candidate| is_file(candidate))
		.map_or_else(|| OsString::from("bash"), PathBuf::into_os_string)
}

#[cfg(windows)]
fn test_bash_candidates() -> Vec<PathBuf> {
	let mut candidates = Vec::new();
	for variable in ["ProgramW6432", "ProgramFiles", "ProgramFiles(x86)"] {
		if let Some(root) = env::var_os(variable) {
			let root = PathBuf::from(root).join("Git");
			candidates.push(root.join("bin/bash.exe"));
			candidates.push(root.join("usr/bin/bash.exe"));
		}
	}
	candidates
}

#[cfg(not(windows))]
fn test_bash_candidates() -> [PathBuf; 0] {
	[]
}

#[cfg(test)]
mod test_bash_tests {
	use super::*;

	#[test]
	fn explicit_test_bash_wins_without_path_guessing() {
		let selected = select_test_bash(
			Some(OsString::from("chosen-bash")),
			[PathBuf::from("installed-bash")],
			|_| true,
		);
		assert_eq!(selected, OsString::from("chosen-bash"));
	}

	#[test]
	fn first_installed_bash_wins_and_missing_candidates_fall_back() {
		let candidates = [PathBuf::from("missing-bash"), PathBuf::from("git-bash")];
		let selected = select_test_bash(None, candidates.clone(), |candidate| {
			candidate == Path::new("git-bash")
		});
		assert_eq!(selected, OsString::from("git-bash"));
		assert_eq!(
			select_test_bash(None, candidates, |_| false),
			OsString::from("bash")
		);
	}
}

#[cfg(all(test, unix))]
mod unix_argument_tests {
	use super::*;
	use std::os::unix::ffi::{OsStrExt, OsStringExt};

	#[test]
	fn non_utf8_random_source_paths_survive_both_spellings() {
		let path = OsString::from_vec(b"/tmp/randomr-source-\xff".to_vec());
		for arguments in [
			vec![
				OsString::from("randomr"),
				OsString::from("--random-source"),
				path.clone(),
			],
			vec![
				OsString::from("randomr"),
				OsString::from_vec([b"--random-source=".as_slice(), path.as_bytes()].concat()),
			],
		] {
			let (text, paths) = normalize_args(&arguments).unwrap();
			let mut options = options::parse(&text, "randomr").unwrap();
			restore_os_path(&mut options, &paths).unwrap();
			assert_eq!(options.random_source.as_deref(), Some(Path::new(&path)));
		}
	}

	#[test]
	fn non_utf8_non_path_argument_is_a_clean_error() {
		let arguments = [
			OsString::from("randomr"),
			OsString::from_vec(b"--unknown-\xff".to_vec()),
		];
		assert_eq!(
			normalize_args(&arguments).unwrap_err(),
			"arguments other than --random-source paths must be valid UTF-8"
		);
	}
}
