import Randoml.Fixed

/- A small exact witness keeps a broken long-division implementation from
being mistaken for merely a slower elaboration of the universal theorem. -/
set_option maxRecDepth 4096 in
example : Randoml.Fixed.divMagnitude 1 3 = (2 ^ 62 : Nat) / 3 := by decide
