use std::env;
use std::io::{self, IsTerminal, Write};

use randomr::{Curve, Distribution, Error, Fixed};

const VIEW_WIDTH: usize = 336;
const VIEW_HEIGHT: usize = 144;
const VIEW_LEFT: i32 = 17;
const VIEW_RIGHT: i32 = VIEW_WIDTH as i32 - 10;
const VIEW_TOP: i32 = 7;
const VIEW_BOTTOM: i32 = VIEW_HEIGHT as i32 - 19;
const BRAILLE_WIDTH: usize = 96;
const BRAILLE_HEIGHT: usize = 32;
const PALETTE: [[u8; 3]; 4] = [[12, 16, 24], [37, 50, 71], [28, 93, 103], [100, 213, 210]];
const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Renderer {
	Utf8,
	Kitty,
	Sixel,
}

pub struct EmbeddedChart {
	pub key: &'static str,
	pub title: &'static str,
	pub parameters: &'static str,
	pub axis: &'static str,
	pub png_base64: &'static str,
	pub sixel_data: &'static str,
	pub fallback: &'static str,
}

include!("generated_charts.rs");

pub fn embedded(key: &str) -> Option<&'static EmbeddedChart> {
	EMBEDDED_CHARTS.iter().find(|chart| chart.key == key)
}

pub fn render_embedded(
	chart: &EmbeddedChart,
	renderer: Renderer,
	output: &mut impl Write,
) -> Result<(), String> {
	match renderer {
		Renderer::Utf8 => output
			.write_all(chart.fallback.as_bytes())
			.map_err(|_| "stdout write failed".to_owned()),
		Renderer::Kitty => {
			let payload = chart.png_base64.as_bytes();
			let tmux = present("TMUX");
			for offset in (0..payload.len()).step_by(4096) {
				let end = (offset + 4096).min(payload.len());
				let final_chunk = end == payload.len();
				let control = if offset == 0 {
					format!(
						"a=T,f=100,t=d,c=56,r=12,C=1,q=2,m={}",
						usize::from(!final_chunk)
					)
				} else {
					format!("m={}", usize::from(!final_chunk))
				};
				kitty_sequence(output, &control, &payload[offset..end], tmux)?;
			}
			for _ in 0..12 {
				output
					.write_all(b"\r\n")
					.map_err(|_| "stdout write failed".to_owned())?;
			}
			Ok(())
		}
		Renderer::Sixel => {
			output
				.write_all(b"\x1b7\x1bP0;1;0q")
				.and_then(|()| output.write_all(chart.sixel_data.as_bytes()))
				.and_then(|()| output.write_all(b"\x1b\\\x1b8"))
				.map_err(|_| "stdout write failed".to_owned())?;
			for _ in 0..12 {
				output
					.write_all(b"\r\n")
					.map_err(|_| "stdout write failed".to_owned())?;
			}
			Ok(())
		}
	}
}

impl Renderer {
	pub fn select(args: &[String]) -> Result<Self, String> {
		let mut selected = None;
		for argument in args.iter().skip(1) {
			match argument.as_str() {
				"--kitty" => selected = Some(Self::Kitty),
				"--sixel" => selected = Some(Self::Sixel),
				"--utf8" | "--utf8-graphics" => selected = Some(Self::Utf8),
				_ => {}
			}
		}
		if let Some(value) = selected {
			return Ok(value);
		}
		if let Some(requested) = env::var_os("RANDOMZ_CHART_TYPE") {
			let requested = requested.to_string_lossy();
			if !requested.is_empty() {
				return match requested.to_ascii_lowercase().as_str() {
					"utf8" => Ok(Self::Utf8),
					"kitty" => Ok(Self::Kitty),
					"sixel" => Ok(Self::Sixel),
					_ => Err("RANDOMZ_CHART_TYPE must be utf8, kitty, or sixel".to_owned()),
				};
			}
		}
		if !io::stdout().is_terminal() || present("TMUX") {
			return Ok(Self::Utf8);
		}
		if present("WEZTERM_PANE")
			|| present("WEZTERM_EXECUTABLE")
			|| env_eq("TERM_PROGRAM", "WezTerm")
		{
			Ok(Self::Sixel)
		} else if env::var("TERM").ok().as_deref() == Some("xterm-kitty")
			|| present("KITTY_WINDOW_ID")
			|| present("GHOSTTY_RESOURCES_DIR")
			|| env_eq("TERM_PROGRAM", "ghostty")
			|| env_eq("TERM_PROGRAM", "kitty")
		{
			Ok(Self::Kitty)
		} else {
			Ok(Self::Utf8)
		}
	}
}

pub fn render(
	distribution: Distribution,
	first: Fixed,
	second: Fixed,
	renderer: Renderer,
	output: &mut impl Write,
) -> Result<(), String> {
	match renderer {
		Renderer::Utf8 => render_braille(distribution, first, second, output),
		Renderer::Kitty | Renderer::Sixel => {
			let canvas = make_canvas(distribution, first, second).map_err(core_error)?;
			if renderer == Renderer::Kitty {
				render_kitty(&canvas, output)
			} else {
				render_sixel(&canvas, output)
			}
		}
	}
}

fn core_error(error: Error) -> String {
	format!("supplied distribution parameters cannot be charted ({error})")
}

fn present(name: &str) -> bool {
	env::var_os(name).is_some_and(|value| !value.is_empty())
}

fn env_eq(name: &str, expected: &str) -> bool {
	env::var(name)
		.ok()
		.is_some_and(|value| value.eq_ignore_ascii_case(expected))
}

fn sampled_curve(
	distribution: Distribution,
	first: Fixed,
	second: Fixed,
	capacity: usize,
) -> Result<(Curve, bool), Error> {
	let curve = Curve::sample(distribution, first, second, capacity)?;
	let discrete = distribution == Distribution::Poisson
		&& curve.x_max.to_i64_trunc() - curve.x_min.to_i64_trunc() < capacity as i64;
	Ok((curve, discrete))
}

fn map_x(index: usize, count: usize, left: i32, right: i32) -> i32 {
	let denominator = (count - 1) as u64;
	let numerator = index as u64 * (right - left) as u64 + denominator / 2;
	left + (numerator / denominator) as i32
}

fn map_y(value: u16, top: i32, bottom: i32) -> i32 {
	let numerator = u64::from(value) * (bottom - top) as u64 + u64::from(u16::MAX) / 2;
	bottom - (numerator / u64::from(u16::MAX)) as i32
}

fn set_pixel(canvas: &mut [u8], width: usize, height: usize, x: i32, y: i32, color: u8) {
	if x >= 0 && y >= 0 && (x as usize) < width && (y as usize) < height {
		canvas[y as usize * width + x as usize] = color;
	}
}

// Keeping the raster dimensions explicit makes this primitive usable for both
// the pixel and Braille canvases without hidden state.
#[allow(clippy::too_many_arguments)]
fn draw_line(
	canvas: &mut [u8],
	width: usize,
	height: usize,
	mut x0: i32,
	mut y0: i32,
	x1: i32,
	y1: i32,
	color: u8,
) {
	let dx = (x1 - x0).abs();
	let sx = if x0 < x1 { 1 } else { -1 };
	let dy = -(y1 - y0).abs();
	let sy = if y0 < y1 { 1 } else { -1 };
	let mut error = dx + dy;
	loop {
		set_pixel(canvas, width, height, x0, y0, color);
		if x0 == x1 && y0 == y1 {
			break;
		}
		let twice = 2 * error;
		if twice >= dy {
			error += dy;
			x0 += sx;
		}
		if twice <= dx {
			error += dx;
			y0 += sy;
		}
	}
}

fn make_canvas(distribution: Distribution, first: Fixed, second: Fixed) -> Result<Vec<u8>, Error> {
	let mut canvas = vec![0; VIEW_WIDTH * VIEW_HEIGHT];
	for division in 1..=3 {
		let y = VIEW_TOP + ((VIEW_BOTTOM - VIEW_TOP) * division + 2) / 4;
		draw_line(
			&mut canvas,
			VIEW_WIDTH,
			VIEW_HEIGHT,
			VIEW_LEFT,
			y,
			VIEW_RIGHT,
			y,
			1,
		);
	}
	for division in 1..=5 {
		let x = VIEW_LEFT + ((VIEW_RIGHT - VIEW_LEFT) * division + 3) / 6;
		draw_line(
			&mut canvas,
			VIEW_WIDTH,
			VIEW_HEIGHT,
			x,
			VIEW_TOP,
			x,
			VIEW_BOTTOM,
			1,
		);
	}
	draw_line(
		&mut canvas,
		VIEW_WIDTH,
		VIEW_HEIGHT,
		VIEW_LEFT,
		VIEW_TOP,
		VIEW_LEFT,
		VIEW_BOTTOM,
		3,
	);
	draw_line(
		&mut canvas,
		VIEW_WIDTH,
		VIEW_HEIGHT,
		VIEW_LEFT,
		VIEW_BOTTOM,
		VIEW_RIGHT,
		VIEW_BOTTOM,
		3,
	);

	let capacity = (VIEW_RIGHT - VIEW_LEFT + 1) as usize;
	let (curve, discrete) = sampled_curve(distribution, first, second, capacity)?;
	if discrete {
		for (index, value) in curve.heights.iter().copied().enumerate() {
			let x = map_x(index, curve.heights.len(), VIEW_LEFT, VIEW_RIGHT);
			let y = map_y(value, VIEW_TOP, VIEW_BOTTOM);
			draw_line(
				&mut canvas,
				VIEW_WIDTH,
				VIEW_HEIGHT,
				x,
				VIEW_BOTTOM - 1,
				x,
				y,
				3,
			);
			for oy in -2..=2 {
				for ox in -2..=2 {
					if ox * ox + oy * oy <= 4 {
						set_pixel(&mut canvas, VIEW_WIDTH, VIEW_HEIGHT, x + ox, y + oy, 3);
					}
				}
			}
		}
	} else {
		let mut previous = None;
		for (index, value) in curve.heights.iter().copied().enumerate() {
			let x = map_x(index, curve.heights.len(), VIEW_LEFT, VIEW_RIGHT);
			let y = map_y(value, VIEW_TOP, VIEW_BOTTOM);
			for fill_y in y + 1..VIEW_BOTTOM {
				set_pixel(&mut canvas, VIEW_WIDTH, VIEW_HEIGHT, x, fill_y, 2);
			}
			if let Some((px, py)) = previous {
				draw_line(&mut canvas, VIEW_WIDTH, VIEW_HEIGHT, px, py, x, y, 3);
			}
			previous = Some((x, y));
		}
	}
	Ok(canvas)
}

fn render_braille(
	distribution: Distribution,
	first: Fixed,
	second: Fixed,
	output: &mut impl Write,
) -> Result<(), String> {
	let mut dots = vec![0; BRAILLE_WIDTH * BRAILLE_HEIGHT];
	draw_line(
		&mut dots,
		BRAILLE_WIDTH,
		BRAILLE_HEIGHT,
		0,
		0,
		0,
		BRAILLE_HEIGHT as i32 - 1,
		1,
	);
	draw_line(
		&mut dots,
		BRAILLE_WIDTH,
		BRAILLE_HEIGHT,
		0,
		BRAILLE_HEIGHT as i32 - 1,
		BRAILLE_WIDTH as i32 - 1,
		BRAILLE_HEIGHT as i32 - 1,
		1,
	);
	let (curve, discrete) =
		sampled_curve(distribution, first, second, BRAILLE_WIDTH).map_err(core_error)?;
	if discrete {
		for (index, value) in curve.heights.iter().copied().enumerate() {
			let x = map_x(index, curve.heights.len(), 0, BRAILLE_WIDTH as i32 - 1);
			let y = map_y(value, 0, BRAILLE_HEIGHT as i32 - 1);
			draw_line(
				&mut dots,
				BRAILLE_WIDTH,
				BRAILLE_HEIGHT,
				x,
				BRAILLE_HEIGHT as i32 - 2,
				x,
				y,
				1,
			);
		}
	} else {
		let mut previous = None;
		for (index, value) in curve.heights.iter().copied().enumerate() {
			let x = map_x(index, curve.heights.len(), 0, BRAILLE_WIDTH as i32 - 1);
			let y = map_y(value, 0, BRAILLE_HEIGHT as i32 - 1);
			if let Some((px, py)) = previous {
				draw_line(&mut dots, BRAILLE_WIDTH, BRAILLE_HEIGHT, px, py, x, y, 1);
			}
			previous = Some((x, y));
		}
	}
	let masks = [[1_u32, 2, 4, 64], [8_u32, 16, 32, 128]];
	let mut bytes = String::new();
	for cell_y in 0..BRAILLE_HEIGHT / 4 {
		for cell_x in 0..BRAILLE_WIDTH / 2 {
			let mut mask = 0_u32;
			for (dx, column) in masks.iter().enumerate() {
				for (dy, dot) in column.iter().enumerate() {
					let x = cell_x * 2 + dx;
					let y = cell_y * 4 + dy;
					if dots[y * BRAILLE_WIDTH + x] != 0 {
						mask += dot;
					}
				}
			}
			bytes.push(char::from_u32(0x2800 + mask).expect("Braille codepoint"));
		}
		bytes.push('\n');
	}
	output
		.write_all(bytes.as_bytes())
		.map_err(|_| "stdout write failed".to_owned())
}

fn render_kitty(canvas: &[u8], output: &mut impl Write) -> Result<(), String> {
	let mut raw = Vec::with_capacity(VIEW_WIDTH * VIEW_HEIGHT * 3);
	for pixel in canvas {
		raw.extend_from_slice(&PALETTE[*pixel as usize]);
	}
	let encoded = base64(&raw);
	let tmux = present("TMUX");
	for offset in (0..encoded.len()).step_by(4096) {
		let end = (offset + 4096).min(encoded.len());
		let final_chunk = end == encoded.len();
		let control = if offset == 0 {
			format!(
				"a=T,f=24,s={VIEW_WIDTH},v={VIEW_HEIGHT},c=56,r=12,C=1,q=2,m={}",
				usize::from(!final_chunk)
			)
		} else {
			format!("m={}", usize::from(!final_chunk))
		};
		kitty_sequence(output, &control, &encoded[offset..end], tmux)?;
	}
	for _ in 0..12 {
		output
			.write_all(b"\r\n")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	Ok(())
}

fn kitty_sequence(
	output: &mut impl Write,
	control: &str,
	payload: &[u8],
	tmux: bool,
) -> Result<(), String> {
	if tmux {
		output
			.write_all(b"\x1bPtmux;\x1b\x1b_G")
			.map_err(|_| "stdout write failed".to_owned())?;
	} else {
		output
			.write_all(b"\x1b_G")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	output
		.write_all(control.as_bytes())
		.map_err(|_| "stdout write failed".to_owned())?;
	output
		.write_all(b";")
		.map_err(|_| "stdout write failed".to_owned())?;
	output
		.write_all(payload)
		.map_err(|_| "stdout write failed".to_owned())?;
	output
		.write_all(if tmux { b"\x1b\x1b\\\x1b\\" } else { b"\x1b\\" })
		.map_err(|_| "stdout write failed".to_owned())
}

fn render_sixel(canvas: &[u8], output: &mut impl Write) -> Result<(), String> {
	write!(output, "\x1b7\x1bP0;1;0q\"1;1;{VIEW_WIDTH};{VIEW_HEIGHT}")
		.map_err(|_| "stdout write failed".to_owned())?;
	for (color, rgb) in PALETTE.iter().enumerate() {
		let red = (u16::from(rgb[0]) * 100 + 127) / 255;
		let green = (u16::from(rgb[1]) * 100 + 127) / 255;
		let blue = (u16::from(rgb[2]) * 100 + 127) / 255;
		write!(output, "#{color};2;{red};{green};{blue}")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	for band_y in (0..VIEW_HEIGHT).step_by(6) {
		for color in 0..4_u8 {
			write!(output, "#{color}").map_err(|_| "stdout write failed".to_owned())?;
			let mut previous = 0_u8;
			let mut run = 0_usize;
			for x in 0..VIEW_WIDTH {
				let mut mask = 0_u8;
				for bit in 0..6 {
					let y = band_y + bit;
					if y < VIEW_HEIGHT && canvas[y * VIEW_WIDTH + x] == color {
						mask |= 1 << bit;
					}
				}
				if run == 0 {
					previous = mask;
					run = 1;
				} else if mask == previous {
					run += 1;
				} else {
					sixel_run(output, previous, run)?;
					previous = mask;
					run = 1;
				}
			}
			sixel_run(output, previous, run)?;
			if color < 3 {
				output
					.write_all(b"$")
					.map_err(|_| "stdout write failed".to_owned())?;
			} else if band_y + 6 < VIEW_HEIGHT {
				output
					.write_all(b"-")
					.map_err(|_| "stdout write failed".to_owned())?;
			}
		}
	}
	output
		.write_all(b"\x1b\\\x1b8")
		.map_err(|_| "stdout write failed".to_owned())?;
	for _ in 0..12 {
		output
			.write_all(b"\r\n")
			.map_err(|_| "stdout write failed".to_owned())?;
	}
	Ok(())
}

fn sixel_run(output: &mut impl Write, mask: u8, count: usize) -> Result<(), String> {
	let pixel = char::from(63 + mask);
	if count >= 4 {
		write!(output, "!{count}{pixel}").map_err(|_| "stdout write failed".to_owned())
	} else {
		for _ in 0..count {
			write!(output, "{pixel}").map_err(|_| "stdout write failed".to_owned())?;
		}
		Ok(())
	}
}

pub fn base64(bytes: &[u8]) -> Vec<u8> {
	let mut output = Vec::with_capacity(bytes.len().div_ceil(3) * 4);
	for chunk in bytes.chunks(3) {
		let a = u32::from(chunk[0]);
		let b = u32::from(*chunk.get(1).unwrap_or(&0));
		let c = u32::from(*chunk.get(2).unwrap_or(&0));
		let value = (a << 16) | (b << 8) | c;
		output.push(BASE64[((value >> 18) & 63) as usize]);
		output.push(BASE64[((value >> 12) & 63) as usize]);
		output.push(if chunk.len() > 1 {
			BASE64[((value >> 6) & 63) as usize]
		} else {
			b'='
		});
		output.push(if chunk.len() > 2 {
			BASE64[(value & 63) as usize]
		} else {
			b'='
		});
	}
	output
}
