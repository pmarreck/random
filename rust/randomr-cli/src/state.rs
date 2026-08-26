use std::collections::BTreeMap;
use std::fmt::Write as _;

use crate::decimal::{parse_fixed, parse_safe_i64};
use crate::options::{Mode, Options, parse_range, parse_seed};

pub const MAX_STATE_BYTES: usize = 1_048_576;
const MAX_JSON_DEPTH: usize = 64;
const MAX_OBJECT_MEMBERS: usize = 32;
const MAX_ARRAY_ITEMS: usize = 1024;

#[derive(Debug)]
enum Json {
	String(String),
	Number(String),
	Bool,
	Array(Vec<Json>),
	Object(BTreeMap<String, Json>),
}

pub fn apply(options: &mut Options, text: &str, positional: &[String]) -> Result<(), String> {
	let root = Parser::new(text).parse()?;
	let Json::Object(mut root) = root else {
		return Err("state JSON must be an object".to_owned());
	};
	for key in root.keys() {
		if !matches!(
			key.as_str(),
			"sv" | "rv" | "seed" | "next_pos" | "args" | "notices" | "warnings"
		) {
			return Err(format!("unknown state key: {key}"));
		}
	}
	if take_number(&mut root, "sv")?.as_deref() != Some("2") {
		return Err("unsupported state schema version".to_owned());
	}
	let _ = take_string(&mut root, "rv")?;
	let seed_text = take_string(&mut root, "seed")?;
	if seed_text.len() != 66 || !seed_text.starts_with("0x") {
		return Err("state seed must be exactly 32 bytes of 0x-prefixed hexadecimal".to_owned());
	}
	let seed = parse_seed(&seed_text).ok_or_else(|| {
		"state seed must be exactly 32 bytes of 0x-prefixed hexadecimal".to_owned()
	})?;
	let position_text = take_string(&mut root, "next_pos")?;
	let position = parse_safe_i64(&position_text)
		.filter(|value| *value >= 0)
		.ok_or_else(|| "state next_pos must be a decimal string no larger than 2^53".to_owned())?
		as u64;
	let args = root
		.remove("args")
		.ok_or_else(|| "state args must be an object".to_owned())?;
	let Json::Object(mut args) = args else {
		return Err("state args must be an object".to_owned());
	};
	for key in ["notices", "warnings"] {
		if let Some(value) = root.remove(key) {
			let Json::Array(values) = value else {
				return Err(format!("state {key} must be an array"));
			};
			if !values.iter().all(|value| matches!(value, Json::String(_))) {
				return Err(format!("state {key} must contain strings"));
			}
		}
	}
	for key in args.keys() {
		if !matches!(
			key.as_str(),
			"op" | "distribution"
				| "range" | "count"
				| "mean" | "stddev"
				| "rate" | "lambda"
				| "alpha" | "beta"
				| "precision"
				| "binary" | "encoding"
				| "delim"
		) {
			return Err(format!("unknown state args key: {key}"));
		}
	}

	let cli_stdin = options.choose || options.shuffle || options.weighted;
	let cli_distribution = options.mode_cli || !positional.is_empty();
	if !cli_stdin && !cli_distribution {
		if let Some(operation) = take_optional_string(&mut args, "op")? {
			match operation.as_str() {
				"choose" => options.choose = true,
				"shuffle" => options.shuffle = true,
				"weighted" => options.weighted = true,
				_ => return Err("state operation is unsupported".to_owned()),
			}
		}
		if let Some(distribution) = take_optional_string(&mut args, "distribution")? {
			options.mode = match distribution.as_str() {
				"uniform" => Mode::Uniform,
				"normal" => Mode::Normal,
				"exponential" => Mode::Exponential,
				"poisson" => Mode::Poisson,
				"log-normal" => Mode::LogNormal,
				"beta" => Mode::Beta,
				_ => return Err("state distribution is unsupported".to_owned()),
			};
			options.mode_count = usize::from(options.mode != Mode::Uniform);
		}
	}
	if options.count.is_none() {
		if let Some(value) = take_optional_string(&mut args, "count")? {
			options.count = Some(
				parse_safe_i64(&value)
					.filter(|count| *count >= 0)
					.ok_or_else(|| "state count is invalid".to_owned())?,
			);
		}
	}
	if options.range.is_none() && positional.is_empty() {
		if let Some(value) = take_optional_string(&mut args, "range")? {
			let Some((first, last)) = value.split_once("..") else {
				return Err("state range must be canonical M..N".to_owned());
			};
			if first.is_empty()
				|| last.is_empty()
				|| last.contains("..")
				|| parse_safe_i64(first).is_none()
				|| parse_safe_i64(last).is_none()
			{
				return Err("state range must be canonical M..N".to_owned());
			}
			options.range = Some(
				parse_range(&value)
					.ok_or_else(|| "state range must be canonical M..N".to_owned())?,
			);
		}
	}
	if !options.delimiter_set {
		if let Some(value) = take_optional_string(&mut args, "delim")? {
			options.delimiter = value;
		}
	}
	if !options.encoding_set {
		if let Some(value) = take_optional_string(&mut args, "encoding")? {
			options.binary = false;
			options.hex = false;
			options.base64 = false;
			match value.as_str() {
				"text" => {}
				"hex" => options.hex = true,
				"raw" => options.binary = true,
				"binary-hex" => {
					options.binary = true;
					options.hex = true;
				}
				"base64" => {
					options.binary = true;
					options.base64 = true;
				}
				_ => return Err("state encoding is unsupported".to_owned()),
			}
		}
	}
	if let Some(value) = args.remove("binary") {
		if !matches!(value, Json::Bool) {
			return Err("state binary must be boolean".to_owned());
		}
	}
	if !(options.choose || options.shuffle || options.weighted) {
		match options.mode {
			Mode::Normal | Mode::LogNormal => {
				inherit_fixed(&mut options.mean, &mut args, "mean")?;
				inherit_fixed(&mut options.stddev, &mut args, "stddev")?;
			}
			Mode::Exponential => inherit_fixed(&mut options.rate, &mut args, "rate")?,
			Mode::Poisson => {
				inherit_fixed(&mut options.mean, &mut args, "mean")?;
				inherit_fixed(&mut options.lambda, &mut args, "lambda")?;
			}
			Mode::Beta => {
				inherit_fixed(&mut options.alpha, &mut args, "alpha")?;
				inherit_fixed(&mut options.beta, &mut args, "beta")?;
			}
			Mode::Uniform => {}
		}
	}
	for (key, value) in [
		("stddev", options.stddev.as_ref()),
		("rate", options.rate.as_ref()),
		("lambda", options.lambda.as_ref()),
		("alpha", options.alpha.as_ref()),
		("beta", options.beta.as_ref()),
	] {
		if value.is_some_and(|value| value.0.m() <= 0) {
			return Err(format!("state {key} must be positive"));
		}
	}
	if !options.precision_set {
		if let Some(value) = take_optional_string(&mut args, "precision")? {
			let precision = parse_safe_i64(&value)
				.filter(|value| (0..=18).contains(value))
				.ok_or_else(|| "state precision is invalid".to_owned())?;
			options.precision = precision as usize;
			options.precision_set = true;
		}
	}
	options.seed = Some(seed);
	options.state_position = Some(position);
	options.deterministic = true;
	Ok(())
}

fn inherit_fixed(
	target: &mut Option<(randomr::Fixed, String)>,
	args: &mut BTreeMap<String, Json>,
	key: &str,
) -> Result<(), String> {
	let Some(text) = take_optional_string(args, key)? else {
		return Ok(());
	};
	if target.is_none() {
		let value = parse_fixed(&text).ok_or_else(|| format!("state {key} is invalid"))?;
		*target = Some((value, text));
	}
	Ok(())
}

fn take_string(map: &mut BTreeMap<String, Json>, key: &str) -> Result<String, String> {
	match map.remove(key) {
		Some(Json::String(value)) => Ok(value),
		_ => Err(format!("state {key} must be a string")),
	}
}

fn take_optional_string(
	map: &mut BTreeMap<String, Json>,
	key: &str,
) -> Result<Option<String>, String> {
	match map.remove(key) {
		Some(Json::String(value)) => Ok(Some(value)),
		Some(_) => Err(format!("state {key} must be a string")),
		None => Ok(None),
	}
}

fn take_number(map: &mut BTreeMap<String, Json>, key: &str) -> Result<Option<String>, String> {
	match map.remove(key) {
		Some(Json::Number(value)) => Ok(Some(value)),
		Some(_) => Err(format!("state {key} must be a number")),
		None => Ok(None),
	}
}

pub fn quote(value: &str) -> String {
	let mut output = String::with_capacity(value.len() + 2);
	output.push('"');
	for character in value.chars() {
		match character {
			'"' => output.push_str("\\\""),
			'\\' => output.push_str("\\\\"),
			'\u{08}' => output.push_str("\\b"),
			'\u{0c}' => output.push_str("\\f"),
			'\n' => output.push_str("\\n"),
			'\r' => output.push_str("\\r"),
			'\t' => output.push_str("\\t"),
			character if character < '\u{20}' => {
				let _ = write!(output, "\\u{:04x}", character as u32);
			}
			character => output.push(character),
		}
	}
	output.push('"');
	output
}

struct Parser<'a> {
	input: &'a [u8],
	index: usize,
}

impl<'a> Parser<'a> {
	fn new(input: &'a str) -> Self {
		Self {
			input: input.as_bytes(),
			index: 0,
		}
	}

	fn parse(mut self) -> Result<Json, String> {
		let value = self.value(0)?;
		self.space();
		if self.index != self.input.len() {
			return Err("invalid state JSON: trailing data".to_owned());
		}
		Ok(value)
	}

	fn value(&mut self, depth: usize) -> Result<Json, String> {
		self.space();
		match self.input.get(self.index) {
			Some(b'"') => self.string().map(Json::String),
			Some(b'{' | b'[') if depth >= MAX_JSON_DEPTH => {
				Err("state JSON nesting exceeds 64 levels".to_owned())
			}
			Some(b'{') => self.object(depth + 1),
			Some(b'[') => self.array(depth + 1),
			Some(b't') if self.literal(b"true") => Ok(Json::Bool),
			Some(b'f') if self.literal(b"false") => Ok(Json::Bool),
			Some(b'-' | b'0'..=b'9') => self.number().map(Json::Number),
			_ => Err("invalid state JSON: malformed value".to_owned()),
		}
	}

	fn object(&mut self, depth: usize) -> Result<Json, String> {
		self.index += 1;
		self.space();
		let mut values = BTreeMap::new();
		if self.consume(b'}') {
			return Ok(Json::Object(values));
		}
		loop {
			if values.len() >= MAX_OBJECT_MEMBERS {
				return Err("state JSON object exceeds 32 members".to_owned());
			}
			let key = self.string()?;
			if values.contains_key(&key) {
				return Err(format!("invalid state JSON: duplicate object key: {key}"));
			}
			self.space();
			if !self.consume(b':') {
				return Err("invalid state JSON: expected colon".to_owned());
			}
			let value = self.value(depth)?;
			values.insert(key, value);
			self.space();
			if self.consume(b'}') {
				break;
			}
			if !self.consume(b',') {
				return Err("invalid state JSON: expected comma or closing brace".to_owned());
			}
			self.space();
		}
		Ok(Json::Object(values))
	}

	fn array(&mut self, depth: usize) -> Result<Json, String> {
		self.index += 1;
		self.space();
		let mut values = Vec::new();
		if self.consume(b']') {
			return Ok(Json::Array(values));
		}
		loop {
			if values.len() >= MAX_ARRAY_ITEMS {
				return Err("state JSON array exceeds 1024 items".to_owned());
			}
			values.push(self.value(depth)?);
			self.space();
			if self.consume(b']') {
				break;
			}
			if !self.consume(b',') {
				return Err("invalid state JSON: expected comma or closing bracket".to_owned());
			}
		}
		Ok(Json::Array(values))
	}

	fn string(&mut self) -> Result<String, String> {
		if !self.consume(b'"') {
			return Err("invalid state JSON: expected string".to_owned());
		}
		let mut output = Vec::new();
		while let Some(&byte) = self.input.get(self.index) {
			self.index += 1;
			match byte {
				b'"' => {
					return String::from_utf8(output)
						.map_err(|_| "invalid state JSON: string is not UTF-8".to_owned());
				}
				b'\\' => self.escape(&mut output)?,
				0..=0x1f => return Err("invalid state JSON: unescaped control byte".to_owned()),
				_ => output.push(byte),
			}
		}
		Err("invalid state JSON: unterminated string".to_owned())
	}

	fn escape(&mut self, output: &mut Vec<u8>) -> Result<(), String> {
		let byte = *self
			.input
			.get(self.index)
			.ok_or_else(|| "invalid state JSON: incomplete escape".to_owned())?;
		self.index += 1;
		match byte {
			b'"' | b'\\' | b'/' => output.push(byte),
			b'b' => output.push(8),
			b'f' => output.push(12),
			b'n' => output.push(b'\n'),
			b'r' => output.push(b'\r'),
			b't' => output.push(b'\t'),
			b'u' => {
				let high = self.hex_quad()?;
				let scalar = if (0xd800..=0xdbff).contains(&high) {
					if !self.consume(b'\\') || !self.consume(b'u') {
						return Err("invalid state JSON: unpaired high surrogate".to_owned());
					}
					let low = self.hex_quad()?;
					if !(0xdc00..=0xdfff).contains(&low) {
						return Err("invalid state JSON: invalid low surrogate".to_owned());
					}
					0x10000 + ((high - 0xd800) << 10) + low - 0xdc00
				} else if (0xdc00..=0xdfff).contains(&high) {
					return Err("invalid state JSON: unpaired low surrogate".to_owned());
				} else {
					high
				};
				if scalar == 0 {
					return Err(
						"invalid state JSON: NUL is not supported in state strings".to_owned()
					);
				}
				let character = char::from_u32(scalar)
					.ok_or_else(|| "invalid state JSON: invalid Unicode scalar".to_owned())?;
				let mut bytes = [0_u8; 4];
				output.extend_from_slice(character.encode_utf8(&mut bytes).as_bytes());
			}
			_ => return Err("invalid state JSON: invalid escape".to_owned()),
		}
		Ok(())
	}

	fn hex_quad(&mut self) -> Result<u32, String> {
		let end = self.index.saturating_add(4);
		let bytes = self
			.input
			.get(self.index..end)
			.ok_or_else(|| "invalid state JSON: incomplete Unicode escape".to_owned())?;
		let mut value = 0_u32;
		for &byte in bytes {
			value = (value << 4)
				| u32::from(
					hex(byte)
						.ok_or_else(|| "invalid state JSON: invalid Unicode escape".to_owned())?,
				);
		}
		self.index = end;
		Ok(value)
	}

	fn number(&mut self) -> Result<String, String> {
		let start = self.index;
		if self.consume(b'-') && !self.input.get(self.index).is_some_and(u8::is_ascii_digit) {
			return Err("invalid state JSON: malformed number".to_owned());
		}
		if self.consume(b'0') {
			if self.input.get(self.index).is_some_and(u8::is_ascii_digit) {
				return Err("invalid state JSON: leading zero".to_owned());
			}
		} else {
			let digits = self.index;
			while self.input.get(self.index).is_some_and(u8::is_ascii_digit) {
				self.index += 1;
			}
			if self.index == digits {
				return Err("invalid state JSON: malformed number".to_owned());
			}
		}
		String::from_utf8(self.input[start..self.index].to_vec())
			.map_err(|_| "invalid state JSON: malformed number".to_owned())
	}

	fn literal(&mut self, literal: &[u8]) -> bool {
		if self.input.get(self.index..self.index + literal.len()) == Some(literal) {
			self.index += literal.len();
			true
		} else {
			false
		}
	}

	fn consume(&mut self, byte: u8) -> bool {
		if self.input.get(self.index) == Some(&byte) {
			self.index += 1;
			true
		} else {
			false
		}
	}

	fn space(&mut self) {
		while self
			.input
			.get(self.index)
			.is_some_and(u8::is_ascii_whitespace)
		{
			self.index += 1;
		}
	}
}

fn hex(byte: u8) -> Option<u8> {
	match byte {
		b'0'..=b'9' => Some(byte - b'0'),
		b'a'..=b'f' => Some(byte - b'a' + 10),
		b'A'..=b'F' => Some(byte - b'A' + 10),
		_ => None,
	}
}
