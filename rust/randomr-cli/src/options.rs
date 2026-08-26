use std::env;
use std::io::{self, Read};
use std::path::PathBuf;

use randomr::Fixed;
use zeroize::Zeroize;

use crate::decimal::{parse_fixed, parse_safe_i64};

const DEFAULT_FRACTION_DIGITS: usize = 18;
const MAX_FRACTION_DIGITS: i64 = 18;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Mode {
	Uniform,
	Normal,
	Exponential,
	Poisson,
	LogNormal,
	Beta,
}

#[derive(Debug)]
pub struct Options {
	pub deterministic: bool,
	pub force_true_random: bool,
	pub mode: Mode,
	pub mode_count: usize,
	pub binary: bool,
	pub hex: bool,
	pub base64: bool,
	pub choose: bool,
	pub shuffle: bool,
	pub weighted: bool,
	pub no_wait: bool,
	pub view: bool,
	pub chart_flag: bool,
	pub generation_seen: bool,
	pub mode_cli: bool,
	pub precision: usize,
	pub precision_set: bool,
	pub delimiter_set: bool,
	pub encoding_set: bool,
	pub state_stdout: bool,
	pub delimiter: String,
	pub random_source: Option<PathBuf>,
	pub count: Option<i64>,
	pub seed: Option<[u8; 32]>,
	pub state_position: Option<u64>,
	pub range: Option<(i64, i64)>,
	pub mean: Option<(Fixed, String)>,
	pub stddev: Option<(Fixed, String)>,
	pub rate: Option<(Fixed, String)>,
	pub lambda: Option<(Fixed, String)>,
	pub alpha: Option<(Fixed, String)>,
	pub beta: Option<(Fixed, String)>,
}

impl Options {
	pub fn new(program: &str) -> Self {
		let normal = normal_invocation(program);
		Self {
			deterministic: deterministic_invocation(program),
			force_true_random: false,
			mode: if normal { Mode::Normal } else { Mode::Uniform },
			mode_count: usize::from(normal),
			binary: false,
			hex: false,
			base64: false,
			choose: false,
			shuffle: false,
			weighted: false,
			no_wait: false,
			view: false,
			chart_flag: false,
			generation_seen: false,
			mode_cli: normal,
			precision: DEFAULT_FRACTION_DIGITS,
			precision_set: false,
			delimiter_set: false,
			encoding_set: false,
			state_stdout: false,
			delimiter: "\n".to_owned(),
			random_source: None,
			count: None,
			seed: None,
			state_position: None,
			range: None,
			mean: None,
			stddev: None,
			rate: None,
			lambda: None,
			alpha: None,
			beta: None,
		}
	}

	fn select(&mut self, mode: Mode) {
		self.mode_cli = true;
		if self.mode_count > 0 && self.mode == mode {
			return;
		}
		self.mode = mode;
		self.mode_count += 1;
	}
}

impl Drop for Options {
	fn drop(&mut self) {
		if let Some(seed) = &mut self.seed {
			seed.zeroize();
		}
	}
}

pub fn parse(args: &[String], program: &str) -> Result<Options, String> {
	let mut options = Options::new(program);
	let mut positional = Vec::new();
	let mut state_text: Option<String> = None;
	let mut state_stdin = false;
	let mut index = 1_usize;
	while index < args.len() {
		let argument = &args[index];
		match argument.as_str() {
			"--deterministic" | "-d" => {
				options.deterministic = true;
				options.generation_seen = true;
			}
			"--true-random" => {
				options.force_true_random = true;
				options.generation_seen = true;
			}
			"--normalized" | "-n" => options.select(Mode::Normal),
			"--exponential" => options.select(Mode::Exponential),
			"--poisson" => options.select(Mode::Poisson),
			"--log-normal" => options.select(Mode::LogNormal),
			"--binaryoutput" | "-b" => {
				options.binary = true;
				options.encoding_set = true;
				options.generation_seen = true;
			}
			"--hex" => {
				options.hex = true;
				options.encoding_set = true;
				options.generation_seen = true;
			}
			"--base64" => {
				options.base64 = true;
				options.encoding_set = true;
				options.generation_seen = true;
			}
			"--state-stdout" => {
				options.state_stdout = true;
				options.deterministic = true;
				options.generation_seen = true;
			}
			"--choose" => {
				options.choose = true;
				options.generation_seen = true;
			}
			"--shuffle" => {
				options.shuffle = true;
				options.generation_seen = true;
			}
			"--weighted" => {
				options.weighted = true;
				options.generation_seen = true;
			}
			"--no-wait" => {
				options.no_wait = true;
				options.generation_seen = true;
			}
			"--view" => options.view = true,
			"--kitty" | "--sixel" | "--utf8" | "--utf8-graphics" => options.chart_flag = true,
			"--random-source" => {
				options.generation_seen = true;
				let value = next(args, &mut index, "--random-source requires a path")?;
				if value.is_empty() {
					return Err("--random-source requires a path".to_owned());
				}
				options.random_source = Some(PathBuf::from(value));
			}
			"--delimiter" | "--delim" => {
				options.generation_seen = true;
				let value = next(args, &mut index, "--delimiter requires a value")?;
				options.delimiter = value.to_owned();
				options.delimiter_set = true;
			}
			"--count" | "-c" => {
				options.generation_seen = true;
				let value = next(args, &mut index, "--count requires a number")?;
				options.count = match parse_safe_i64(value) {
					Some(number) if number >= 0 => Some(number),
					_ => {
						return Err(
							"--count must be a nonnegative whole number no larger than 2^53"
								.to_owned(),
						);
					}
				};
			}
			"--precision" | "--truncate" => {
				options.generation_seen = true;
				let value = next(args, &mut index, &format!("{argument} requires a number"))?;
				set_precision(&mut options, argument, value)?;
			}
			"--seed" => {
				options.generation_seen = true;
				let value = next(args, &mut index, "--seed requires a value")?;
				options.seed = Some(parse_seed(value).ok_or_else(|| {
                    format!(
                        "--seed must be an unsigned decimal or 0x-prefixed hexadecimal integer smaller than 2^256, got: {value}"
                    )
                })?);
				options.deterministic = true;
			}
			"--state" | "--resume" => {
				options.generation_seen = true;
				if state_text.is_some() || state_stdin {
					return Err("only one --state/--resume may be specified".to_owned());
				}
				match args.get(index + 1).map(String::as_str) {
					Some("-") => {
						index += 1;
						state_stdin = true;
					}
					Some(candidate) if candidate.trim_start().starts_with('{') => {
						index += 1;
						state_text = Some(candidate.to_owned());
					}
					_ => state_stdin = true,
				}
				options.deterministic = true;
			}
			"--mean" | "--stddev" | "--rate" | "--lambda" | "--alpha" => {
				let value = next(args, &mut index, &format!("{argument} requires a number"))?;
				set_fixed(&mut options, argument, value)?;
			}
			"--beta" => {
				options.select(Mode::Beta);
				if let Some(candidate) = args.get(index + 1) {
					let numeric = parse_fixed(candidate).is_some();
					let range = parse_range(candidate).is_some();
					if numeric || (!candidate.starts_with('-') && !range) {
						index += 1;
						set_beta(&mut options, candidate)?;
					}
				}
			}
			_ if argument.starts_with("--beta=") => {
				options.select(Mode::Beta);
				set_beta(&mut options, &argument[7..])?;
			}
			_ if argument.starts_with("--random-source=") => {
				options.generation_seen = true;
				let value = &argument[16..];
				if value.is_empty() {
					return Err("--random-source requires a path".to_owned());
				}
				options.random_source = Some(PathBuf::from(value));
			}
			_ if argument.starts_with("--state=") || argument.starts_with("--resume=") => {
				options.generation_seen = true;
				if state_text.is_some() || state_stdin {
					return Err("only one --state/--resume may be specified".to_owned());
				}
				let value = argument.split_once('=').unwrap().1;
				if value.is_empty() {
					return Err("--state/--resume= requires inline JSON or '-'".to_owned());
				}
				if value == "-" {
					state_stdin = true;
				} else {
					state_text = Some(value.to_owned());
				}
				options.deterministic = true;
			}
			_ if argument.starts_with("--precision=") || argument.starts_with("--truncate=") => {
				options.generation_seen = true;
				let (name, value) = argument.split_once('=').unwrap();
				set_precision(&mut options, name, value)?;
			}
			_ if attached_name(argument).is_some() => {
				let (name, value) = attached_name(argument).unwrap();
				set_fixed(&mut options, name, value)?;
			}
			_ if argument.starts_with("--") => {
				return Err(format!("unknown option: {argument}"));
			}
			_ => positional.push(argument.clone()),
		}
		index += 1;
	}

	let state_requested = state_text.is_some() || state_stdin;
	if state_requested && options.seed.is_some() {
		return Err("--state/--resume and --seed are mutually exclusive".to_owned());
	}
	if state_requested && options.random_source.is_some() {
		return Err("--state/--resume cannot be combined with --random-source".to_owned());
	}
	if state_requested && options.no_wait {
		return Err("--state/--resume cannot be combined with --no-wait".to_owned());
	}
	if state_stdin && (options.choose || options.shuffle || options.weighted) {
		return Err("--choose, --shuffle, and --weighted require inline --state JSON".to_owned());
	}
	if state_stdin {
		let mut bytes = Vec::new();
		io::stdin()
			.take((crate::state::MAX_STATE_BYTES + 1) as u64)
			.read_to_end(&mut bytes)
			.map_err(|_| "could not read state JSON from stdin".to_owned())?;
		if bytes.len() > crate::state::MAX_STATE_BYTES {
			return Err("state JSON exceeds 1048576 bytes".to_owned());
		}
		let text =
			String::from_utf8(bytes).map_err(|_| "state JSON on stdin must be UTF-8".to_owned())?;
		let text = text.trim();
		if text.is_empty() {
			return Err("--state expected one JSON object on stdin".to_owned());
		}
		state_text = Some(text.to_owned());
	}
	if let Some(text) = state_text.as_deref() {
		crate::state::apply(&mut options, text, &positional)?;
		if state_stdin && (options.choose || options.shuffle || options.weighted) {
			return Err(
				"--choose, --shuffle, and --weighted require inline --state JSON".to_owned(),
			);
		}
	}

	if options.view && !positional.is_empty() {
		return Err("--view does not accept a range".to_owned());
	}
	if positional.len() > 1 {
		return Err("expected at most one range (dN, M-N, M..N, or M...N)".to_owned());
	}
	if !positional.is_empty() && !matches!(options.mode, Mode::Uniform | Mode::Normal) {
		return Err("ranges do not apply to the selected distribution".to_owned());
	}
	if !positional.is_empty()
		&& options.mode == Mode::Normal
		&& (options.mean.is_some() || options.stddev.is_some())
	{
		return Err("a range cannot be combined with custom normal parameters".to_owned());
	}
	if let Some(literal) = positional.first() {
		if literal
			.split_once("...")
			.and_then(|(first, last)| Some((parse_safe_i64(first)?, parse_safe_i64(last)?)))
			.is_some_and(|(first, last)| first >= last)
		{
			return Err("an end-exclusive range must have M < N".to_owned());
		}
		options.range = Some(parse_range(literal).ok_or_else(|| {
			"range must be dN, M-N, M..N, or M...N using positive dN and whole-number bounds no larger than 2^53 in magnitude"
				.to_owned()
		})?);
	}
	if options.mode_count > 1 {
		return Err("only one distribution type can be specified".to_owned());
	}
	if options.chart_flag && !options.view {
		return Err(
			"--kitty, --sixel, --utf8, and --utf8-graphics require --help or --view".to_owned(),
		);
	}
	if options.view && options.mode_count != 1 {
		return Err("--view requires exactly one alternate distribution".to_owned());
	}
	if options.view && options.generation_seen {
		return Err(
			"--view cannot be combined with generation, stdin, range, or output options".to_owned(),
		);
	}
	if usize::from(options.choose) + usize::from(options.shuffle) + usize::from(options.weighted)
		> 1
	{
		return Err("only one stdin operation can be specified".to_owned());
	}
	if options.base64 && !options.binary {
		return Err("--base64 requires --binaryoutput".to_owned());
	}
	if options.state_stdout && options.binary && !options.hex && !options.base64 {
		return Err("--state-stdout requires --hex or --base64 with binary output".to_owned());
	}
	if options.state_stdout && options.force_true_random {
		return Err("--state-stdout cannot be combined with --true-random".to_owned());
	}
	if options.hex && options.base64 {
		return Err("--hex and --base64 are mutually exclusive".to_owned());
	}
	if options.binary && options.precision_set {
		return Err("--precision/--truncate do not apply to binary output".to_owned());
	}
	if options.mean.is_some()
		&& !matches!(options.mode, Mode::Normal | Mode::Poisson | Mode::LogNormal)
	{
		return Err("--mean is not used by the selected distribution".to_owned());
	}
	if options.stddev.is_some() && !matches!(options.mode, Mode::Normal | Mode::LogNormal) {
		return Err("--stddev is not used by the selected distribution".to_owned());
	}
	if options.rate.is_some() && options.mode != Mode::Exponential {
		return Err("--rate requires --exponential".to_owned());
	}
	if options.lambda.is_some() && options.mode != Mode::Poisson {
		return Err("--lambda requires --poisson".to_owned());
	}
	if options.mode == Mode::Poisson && options.lambda.is_some() && options.mean.is_some() {
		return Err("--lambda and --mean are aliases; specify only one".to_owned());
	}
	if options.alpha.is_some() && options.mode != Mode::Beta {
		return Err("--alpha requires --beta".to_owned());
	}
	if options.force_true_random && options.deterministic {
		return Err(
			"--true-random cannot be combined with --deterministic, --seed, or drandomr".to_owned(),
		);
	}
	if options.mode == Mode::Poisson
		&& options
			.mean
			.as_ref()
			.is_some_and(|(value, _)| value.m() <= 0)
	{
		return Err("--mean must be positive for --poisson (it is the rate parameter)".to_owned());
	}
	if !options.force_true_random
		&& !options.deterministic
		&& env::var_os("DRANDOMR_SEED").is_some_and(|value| !value.is_empty())
	{
		options.deterministic = true;
	}
	Ok(options)
}

pub fn parse_seed(text: &str) -> Option<[u8; 32]> {
	if text.is_empty() {
		return None;
	}
	let mut output = [0_u8; 32];
	if let Some(digits) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
		if digits.is_empty()
			|| digits.len() > 64
			|| !digits.bytes().all(|byte| byte.is_ascii_hexdigit())
		{
			return None;
		}
		let mut byte_index = 32 - digits.len().div_ceil(2);
		let mut digit_index = 0;
		if digits.len() % 2 != 0 {
			output[byte_index] = hex(digits.as_bytes()[0])?;
			byte_index += 1;
			digit_index = 1;
		}
		while digit_index < digits.len() {
			output[byte_index] = (hex(digits.as_bytes()[digit_index])? << 4)
				| hex(digits.as_bytes()[digit_index + 1])?;
			byte_index += 1;
			digit_index += 2;
		}
		return Some(output);
	}
	if !text.bytes().all(|byte| byte.is_ascii_digit()) {
		return None;
	}
	for digit in text.bytes() {
		let mut carry = u16::from(digit - b'0');
		for byte in output.iter_mut().rev() {
			let value = u16::from(*byte) * 10 + carry;
			*byte = value as u8;
			carry = value >> 8;
		}
		if carry != 0 {
			return None;
		}
	}
	Some(output)
}

pub fn parse_range(text: &str) -> Option<(i64, i64)> {
	if let Some(faces) = text.strip_prefix('d') {
		let faces = parse_safe_i64(faces)?;
		return (faces >= 1).then_some((1, faces));
	}
	let (separator, length, exclusive) = if let Some(index) = text.find("...") {
		(index, 3, true)
	} else if let Some(index) = text.find("..") {
		(index, 2, false)
	} else {
		let start = usize::from(text.starts_with(['+', '-']));
		(
			text[start..].find('-').map(|index| index + start)?,
			1,
			false,
		)
	};
	let first = parse_safe_i64(&text[..separator])?;
	let mut last = parse_safe_i64(&text[separator + length..])?;
	if exclusive {
		if first >= last {
			return None;
		}
		last -= 1;
	}
	Some((first, last))
}

pub fn normal_invocation(program: &str) -> bool {
	matches!(strip_exe(program), "nrandom" | "nrandomz" | "nrandomr")
}

pub fn deterministic_invocation(program: &str) -> bool {
	matches!(strip_exe(program), "drandom" | "drandomz" | "drandomr")
}

fn strip_exe(program: &str) -> &str {
	program
		.strip_suffix(".exe")
		.or_else(|| program.strip_suffix(".EXE"))
		.unwrap_or(program)
}

fn next<'a>(args: &'a [String], index: &mut usize, message: &str) -> Result<&'a str, String> {
	*index += 1;
	args.get(*index)
		.map(String::as_str)
		.ok_or_else(|| message.to_owned())
}

fn attached_name(argument: &str) -> Option<(&str, &str)> {
	for name in ["--mean", "--stddev", "--rate", "--lambda", "--alpha"] {
		if let Some(value) = argument
			.strip_prefix(name)
			.and_then(|tail| tail.strip_prefix('='))
		{
			return Some((name, value));
		}
	}
	None
}

fn set_fixed(options: &mut Options, name: &str, text: &str) -> Result<(), String> {
	if text.is_empty() {
		return Err(format!("{name} requires a number"));
	}
	let value = parse_fixed(text).ok_or_else(|| format!("{name} value must be a number"))?;
	match name {
		"--mean" => options.mean = Some((value, text.to_owned())),
		"--stddev" if value.m() <= 0 => return Err("--stddev must be positive".to_owned()),
		"--stddev" => options.stddev = Some((value, text.to_owned())),
		"--rate" if value.m() <= 0 => return Err("--rate must be positive".to_owned()),
		"--rate" => options.rate = Some((value, text.to_owned())),
		"--lambda" if value.m() <= 0 => return Err("--lambda must be positive".to_owned()),
		"--lambda" => options.lambda = Some((value, text.to_owned())),
		"--alpha" if value.m() <= 0 => return Err("--alpha must be positive".to_owned()),
		"--alpha" => options.alpha = Some((value, text.to_owned())),
		_ => unreachable!(),
	}
	Ok(())
}

fn set_beta(options: &mut Options, text: &str) -> Result<(), String> {
	if text.is_empty() {
		return Err("--beta value must be a number".to_owned());
	}
	let value = parse_fixed(text).ok_or_else(|| "--beta value must be a number".to_owned())?;
	if value.m() <= 0 {
		return Err("--beta parameter must be positive".to_owned());
	}
	options.beta = Some((value, text.to_owned()));
	Ok(())
}

fn set_precision(options: &mut Options, name: &str, text: &str) -> Result<(), String> {
	if text.is_empty() {
		return Err(format!("{name} requires a number"));
	}
	let value = parse_safe_i64(text)
		.filter(|value| (0..=MAX_FRACTION_DIGITS).contains(value))
		.ok_or_else(|| format!("{name} must be a whole number from 0 to 18"))?;
	options.precision = value as usize;
	options.precision_set = true;
	Ok(())
}

fn hex(byte: u8) -> Option<u8> {
	match byte {
		b'0'..=b'9' => Some(byte - b'0'),
		b'a'..=b'f' => Some(byte - b'a' + 10),
		b'A'..=b'F' => Some(byte - b'A' + 10),
		_ => None,
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn seed_spellings_are_one_u256() {
		assert_eq!(parse_seed("42"), parse_seed("0x2a"));
		assert!(parse_seed("-1").is_none());
		assert!(parse_seed(&format!("0x1{}", "0".repeat(64))).is_none());
	}

	#[test]
	fn ruby_range_convention_is_pinned() {
		assert_eq!(parse_range("1..3"), Some((1, 3)));
		assert_eq!(parse_range("1...3"), Some((1, 2)));
		assert_eq!(parse_range("-17-981"), Some((-17, 981)));
		assert_eq!(parse_range("1...1"), None);
	}

	#[test]
	fn die_notation_is_an_inclusive_one_to_n_range() {
		assert_eq!(parse_range("d6"), Some((1, 6)));
		assert_eq!(parse_range("d20"), Some((1, 20)));
		assert_eq!(parse_range("d1"), Some((1, 1)));
		for invalid in ["d", "d0", "d-6", "d6.0", "D6", "d9007199254740993"] {
			assert_eq!(parse_range(invalid), None, "accepted {invalid}");
		}
	}

	#[test]
	fn fractional_precision_is_bounded_and_binary_rejects_it() {
		let args = ["randomr", "--exponential", "--precision=18"].map(str::to_owned);
		let parsed = parse(&args, "randomr").unwrap();
		assert_eq!(parsed.precision, 18);
		assert!(parsed.precision_set);

		let too_deep = ["randomr", "--exponential", "--truncate", "19"].map(str::to_owned);
		assert!(parse(&too_deep, "randomr").is_err());

		let binary = ["randomr", "--binaryoutput", "--precision", "6"].map(str::to_owned);
		assert!(parse(&binary, "randomr").is_err());
	}
}
