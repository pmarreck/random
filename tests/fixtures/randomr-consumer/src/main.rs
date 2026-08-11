use randomr::{Drbg, Fixed, normal};

fn main() {
    let mut source = Drbg::new(&[0x42; 32]);
    let _value = normal(&mut source, Fixed::ZERO, Fixed::from_i64(1))
        .expect("valid parameters");
}
