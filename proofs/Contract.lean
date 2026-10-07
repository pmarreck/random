import DistributionProofs.Uniform
import DistributionProofs.Geometric
import DistributionProofs.Fixed

/- The statements below are deliberately restated, not just checked by name.
   They are first-stage obligations, not a certificate for every sampler. -/

example (size : ℕ) (hs : 0 < size) (x : ℝ) :
    |DistributionProofs.Uniform.gridCdf size x - DistributionProofs.Uniform.idealCdf x| ≤
      1 / (size : ℝ) :=
  DistributionProofs.Uniform.grid_cdf_bound size hs x

example (x : ℝ) :
    |DistributionProofs.Uniform.gridCdf (2 ^ 32) x - DistributionProofs.Uniform.idealCdf x| ≤
      1 / 4294967296 := by
  exact DistributionProofs.Uniform.grid_cdf_bound (2 ^ 32) (by norm_num) x

#print axioms DistributionProofs.Uniform.grid_cdf_bound
#print axioms DistributionProofs.Uniform.grid_bound_at_zero

example (x : ℝ) :
    |DistributionProofs.Uniform.productionCdf x - DistributionProofs.Uniform.idealCdf x| ≤
      1 / 4294967296 := DistributionProofs.Uniform.production_cdf_bound x

example (state next : Randoml.Drbg) (draw : UInt32)
    (read : state.nextU32 = some (draw, next)) :
    ∃ sample, Randoml.uniform state = some (sample, next) ∧
      DistributionProofs.Fixed.toReal sample.value = (draw.toNat : ℝ) / 4294967296 :=
  DistributionProofs.Uniform.uniform_of_read state next draw read

example (size : ℕ) (hs : 1 < size) (x : ℝ) :
    |DistributionProofs.Uniform.positiveGridCdf size x -
      DistributionProofs.Uniform.idealCdf x| ≤ 1 / (size : ℝ) :=
  DistributionProofs.Uniform.positive_grid_cdf_bound size hs x

example (state next : Randoml.Drbg) (draw : UInt32)
    (read : state.nextU32 = some (draw, next)) :
    ∃ sample, Randoml.nonzeroUniform state = some (sample, next) ∧
      DistributionProofs.Fixed.toReal sample.value =
        ((max 1 draw.toNat : ℕ) : ℝ) / 4294967296 :=
  DistributionProofs.Uniform.nonzero_of_read state next draw read

#print axioms DistributionProofs.Uniform.production_cdf_bound
#print axioms DistributionProofs.Uniform.uniform_of_read
#print axioms DistributionProofs.Uniform.positive_grid_cdf_bound
#print axioms DistributionProofs.Uniform.nonzero_of_read

example (x : ℝ) :
    |DistributionProofs.Uniform.nonzeroProductionCdf x -
      DistributionProofs.Uniform.idealCdf x| ≤ 1 / 4294967296 :=
  DistributionProofs.Uniform.nonzero_production_cdf_bound x

#print axioms DistributionProofs.Uniform.nonzero_production_cdf_bound

example (p : ℝ) (h : 0 < p ∧ p ≤ 1) (n : ℕ) :
  (1 - (2 * p - p ^ 2)) ^ n * (2 * p - p ^ 2) *
    (1 / (2 - p)) = (1 - p) ^ (2 * n) * p :=
  DistributionProofs.Geometric.even_mass p h n

example (p : ℝ) (h : 0 < p ∧ p ≤ 1) (n : ℕ) :
  (1 - (2 * p - p ^ 2)) ^ n * (2 * p - p ^ 2) *
    ((1 - p) / (2 - p)) = (1 - p) ^ (2 * n + 1) * p :=
  DistributionProofs.Geometric.odd_mass p h n

#print axioms DistributionProofs.Geometric.even_mass
#print axioms DistributionProofs.Geometric.odd_mass

example (a b : ℕ) (hb : 0 < b) :
  Randoml.Fixed.divMagnitude a b = a * 2 ^ 62 / b :=
  DistributionProofs.Fixed.divMagnitude_exact a b hb

#print axioms DistributionProofs.Fixed.divMagnitude_exact

example (a b : ℕ) (hb : 0 < b) :
    0 ≤ (a : ℝ) * 2 ^ 62 / (b : ℝ) - (Randoml.Fixed.divMagnitude a b : ℝ) ∧
      (a : ℝ) * 2 ^ 62 / (b : ℝ) - (Randoml.Fixed.divMagnitude a b : ℝ) < 1 :=
  DistributionProofs.Fixed.divMagnitude_rounding a b hb

#print axioms DistributionProofs.Fixed.divMagnitude_rounding

open scoped NNReal ENNReal

example (base : UInt64) :
    DistributionProofs.Geometric.uniformWords.map
      (fun word => decide (word < base.toNat)) =
      PMF.bernoulli (DistributionProofs.Geometric.thresholdProbability base)
        (DistributionProofs.Geometric.threshold_probability_le_one base) :=
  DistributionProofs.Geometric.uniform_word_threshold base

example (read : ℕ → PMF ByteArray) (base : UInt64) (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (DistributionProofs.Geometric.observation base) =
      (PMF.bernoulli p hp).map some) (fuel count k : ℕ) :
    DistributionProofs.Geometric.baseLaw read base fuel count (some k) =
      if count ≤ k ∧ k < count + fuel then
        (1 - (p : ℝ≥0∞)) ^ (k - count) * (p : ℝ≥0∞) else 0 :=
  DistributionProofs.Geometric.base_success_mass read base p hp source fuel count k

example (read : ℕ → PMF ByteArray) (base : UInt64) (p : ℝ≥0) (hp : p ≤ 1)
    (source : (read 8).map (DistributionProofs.Geometric.observation base) =
      (PMF.bernoulli p hp).map some) (fuel count : ℕ) :
    DistributionProofs.Geometric.baseLaw read base fuel count none =
      (1 - (p : ℝ≥0∞)) ^ fuel :=
  DistributionProofs.Geometric.base_failure_mass read base p hp source fuel count

example (read : ℕ → PMF ByteArray) (fuel : ℕ) (prepared : Randoml.Geometric.Prepared)
    (certain : prepared.certain = false) (levels : prepared.levels = #[])
    (tail : prepared.tailBits = 0) :
    Randoml.Geometric.sampleWith read fuel prepared =
      DistributionProofs.Geometric.baseLaw read prepared.base fuel 0 :=
  DistributionProofs.Geometric.sample_with_base_only read fuel prepared certain levels tail

#print axioms DistributionProofs.Geometric.uniform_word_threshold
#print axioms DistributionProofs.Geometric.uniform_source_observer
#print axioms DistributionProofs.Geometric.base_success_mass
#print axioms DistributionProofs.Geometric.base_failure_mass
#print axioms DistributionProofs.Geometric.sample_with_base_only

example (mantissa : ℕ) (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63)
    (read : ℕ → PMF ByteArray)
    (source : (read 8).map DistributionProofs.Geometric.decodedWord =
      DistributionProofs.Geometric.uniformWords.map some) (fuel : ℕ) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      (∀ n, |DistributionProofs.Geometric.samplerCdf read prepared fuel n -
        (1 - (1 - DistributionProofs.Fixed.toReal { m := mantissa, e := -1 }) ^ n)| ≤
          (1 - DistributionProofs.Fixed.toReal { m := mantissa, e := -1 }) ^ fuel) ∧
      (Randoml.Geometric.sampleWith read fuel prepared none).toReal =
        (1 - DistributionProofs.Fixed.toReal { m := mantissa, e := -1 }) ^ fuel ∧
      (1 - DistributionProofs.Fixed.toReal { m := mantissa, e := -1 }) ^ fuel ≤
        (1 / 2 : ℝ) ^ fuel :=
  DistributionProofs.Geometric.direct_sampler_bound mantissa lower upper read source fuel

example (mantissa : ℕ) (lower : 2 ^ 62 ≤ mantissa) (upper : mantissa < 2 ^ 63)
    (read : ℕ → PMF ByteArray)
    (source : (read 8).map DistributionProofs.Geometric.decodedWord =
      DistributionProofs.Geometric.uniformWords.map some) :
    ∃ prepared, Randoml.Geometric.prepare { m := mantissa, e := -1 } = some prepared ∧
      (∀ n, |DistributionProofs.Geometric.samplerCdf read prepared 64 n -
        (1 - (1 - DistributionProofs.Fixed.toReal { m := mantissa, e := -1 }) ^ n)| ≤
          1 / 18446744073709551616) ∧
      (Randoml.Geometric.sampleWith read 64 prepared none).toReal ≤
        1 / 18446744073709551616 :=
  DistributionProofs.Geometric.direct_sampler_64 mantissa lower upper read source

#print axioms DistributionProofs.Geometric.direct_preparation
#print axioms DistributionProofs.Geometric.direct_threshold_exact
#print axioms DistributionProofs.Geometric.base_cdf_bound
#print axioms DistributionProofs.Geometric.direct_sampler_bound
#print axioms DistributionProofs.Geometric.direct_sampler_64
