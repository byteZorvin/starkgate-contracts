// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts for Cairo v0.8.0-beta.1 (utils/structs/checkpoints.cairo)

use core::num::traits::Sqrt;
use openzeppelin::utils::math;
use super::storage_array::StorageArray;
use super::storage_array::StorageArrayTrait;

/// `Trace` struct, for checkpointing values as they change at different points in
/// time, and later looking up past values by block timestamp.
#[derive(Copy, Drop, starknet::Store)]
struct Trace {
    checkpoints: StorageArray<Checkpoint>,
}

/// Generic checkpoint representation.
#[derive(Copy, Drop, Serde)]
struct Checkpoint {
    key: u64,
    value: u256,
}

#[generate_trait]
impl TraceImpl of TraceTrait {
    /// Pushes a (`key`, `value`) pair into a Trace so that it is stored as the checkpoint
    /// and returns previous value and new value.
    fn push(ref self: Trace, key: u64, value: u256) -> (u256, u256) {
        self.checkpoints._insert(key, value)
    }

    /// Returns the value in the last (most recent) checkpoint with key lower or equal
    /// than the search key, or zero if there is none.
    fn upper_lookup(self: @Trace, key: u64) -> u256 {
        let checkpoints = self.checkpoints;
        let len = checkpoints.len();
        let pos = checkpoints._upper_binary_lookup(key, 0, len);

        if pos == 0 {
            0
        } else {
            checkpoints.read_at(pos - 1).value
        }
    }

    /// Returns the value in the last (most recent) checkpoint with key lower or equal
    /// than the search key, or zero if there is none.
    ///
    /// NOTE: This is a variant of {upper_lookup} that is optimised to
    /// find "recent" checkpoint (checkpoints with high keys).
    fn upper_lookup_recent(self: @Trace, key: u64) -> u256 {
        let checkpoints = self.checkpoints;
        let len = checkpoints.len();

        let mut low = 0;
        let mut high = len;

        if (len > 5) {
            let mid = len - len.sqrt().into();
            if (key < checkpoints.read_at(mid).key) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        let pos = checkpoints._upper_binary_lookup(key, low, high);

        if pos == 0 {
            0
        } else {
            checkpoints.read_at(pos - 1).value
        }
    }

    /// Returns the value in the most recent checkpoint, or zero if there are no checkpoints.
    fn latest(self: @Trace) -> u256 {
        let checkpoints = self.checkpoints;
        let pos = checkpoints.len();

        if pos == 0 {
            0
        } else {
            checkpoints.read_at(pos - 1).value
        }
    }

    /// Returns whether there is a checkpoint in the structure (i.e. it is not empty),
    /// and if so the key and value in the most recent checkpoint.
    fn latest_checkpoint(self: @Trace) -> (bool, u64, u256) {
        let checkpoints = self.checkpoints;
        let pos = checkpoints.len();

        if (pos == 0) {
            (false, 0, 0)
        } else {
            let checkpoint: Checkpoint = checkpoints.read_at(pos - 1);
            (true, checkpoint.key, checkpoint.value)
        }
    }

    /// Returns the number of checkpoints.
    fn length(self: @Trace) -> u32 {
        self.checkpoints.len()
    }

    /// Returns the checkpoint at given position.
    fn at(self: @Trace, pos: u32) -> Checkpoint {
        assert(pos < self.length(), 'Array overflow');
        self.checkpoints.read_at(pos)
    }
}

#[generate_trait]
impl CheckpointImpl of CheckpointTrait {
    /// Pushes a (`key`, `value`) pair into an ordered list of checkpoints,
    /// either by inserting a new checkpoint, or by updating the last one.
    fn _insert(ref self: StorageArray<Checkpoint>, key: u64, value: u256) -> (u256, u256) {
        let pos = self.len();

        if (pos > 0) {
            let mut last: Checkpoint = self.read_at(pos - 1);

            // Checkpoint keys must be non-decreasing.
            assert(last.key <= key, 'Unordered insertion');

            // Update or append new checkpoint.
            let prev = last.value;
            if (last.key == key) {
                last.value = value;
                self.write_at(pos - 1, last);
            } else {
                self.append(Checkpoint { key: key, value: value });
            }
            (prev, value)
        } else {
            self.append(Checkpoint { key: key, value: value });
            (0, value)
        }
    }

    /// Return the index of the last (most recent) checkpoint with key lower or equal
    /// than the search key, or `high` if there is none. `low` and `high` define a section
    /// where to do the search, with inclusive `low` and exclusive `high`.
    fn _upper_binary_lookup(self: @StorageArray<Checkpoint>, key: u64, low: u32, high: u32) -> u32 {
        let mut _low = low;
        let mut _high = high;
        loop {
            if _low >= _high {
                break;
            }
            let mid = math::average(_low, _high);
            if (self.read_at(mid).key > key) {
                _high = mid;
            } else {
                _low = mid + 1;
            };
        };
        _high
    }
}

const _2_POW_184: felt252 = 0x10000000000000000000000000000000000000000000000;

/// Packs a Checkpoint into a (felt252, felt252).
///
/// The packing is done as follows:
/// - The first felt of the tuple contains `key` and `value.low`.
/// - In this first felt, the first four bits are skipped to avoid representation errors due
///   to `felt252` max value being a bit less than a 252 bits number max value
///   (https://docs.starknet.io/documentation/architecture_and_concepts/Cryptography/p-value/).
/// - `key` is stored at range [4,67] bits (0-indexed), taking most significant usable bits.
/// - `value.low` is stored at range [124, 251], taking the less significant bits (at the end).
/// - `value.high` is stored as the second tuple element.
impl CheckpointStorePacking of starknet::StorePacking<Checkpoint, (felt252, felt252)> {
    fn pack(value: Checkpoint) -> (felt252, felt252) {
        let checkpoint = value;
        // shift-left by 184 bits
        let key = checkpoint.key.into() * _2_POW_184;
        let key_and_low = key + checkpoint.value.low.into();

        (key_and_low, checkpoint.value.high.into())
    }

    fn unpack(value: (felt252, felt252)) -> Checkpoint {
        let (key_and_low, high) = value;

        let key_and_low: u256 = key_and_low.into();
        // shift-right by 184 bits
        let key: u256 = key_and_low / _2_POW_184.into();
        let low = key_and_low & 0xffffffffffffffffffffffffffffffff;

        Checkpoint {
            key: key.try_into().unwrap(),
            value: u256 { low: low.try_into().unwrap(), high: high.try_into().unwrap() },
        }
    }
}

#[cfg(test)]
mod test {
    use core::num::traits::Bounded;
    use super::Checkpoint;
    use super::CheckpointStorePacking;
    use super::_2_POW_184;

    const KEY_MASK: u256 = 0xffffffffffffffff;
    const LOW_MASK: u256 = 0xffffffffffffffffffffffffffffffff;

    #[test]
    #[available_gas(2000000)]
    fn test_pack_big_key_and_value() {
        let key = Bounded::MAX;
        let value = Bounded::MAX;
        let checkpoint = Checkpoint { key, value };

        let (key_and_low, _) = CheckpointStorePacking::pack(checkpoint);

        let expected_key: u256 = (key_and_low.into() / _2_POW_184.into()) & KEY_MASK;
        let expected_low: u256 = key_and_low.into() & LOW_MASK;

        assert(key.into() == expected_key, 'Invalid key');
        assert(value.low.into() == expected_low, 'Invalid low');
    }

    #[test]
    #[available_gas(2000000)]
    fn test_unpack_big_key_and_value() {
        let key_and_low = Bounded::<u64>::MAX.into() * _2_POW_184 + Bounded::<u128>::MAX.into();
        let high = Bounded::<u128>::MAX.into();

        let checkpoint = CheckpointStorePacking::unpack((key_and_low, high));

        let expected_key: u64 = Bounded::MAX;
        let expected_value: u256 = Bounded::MAX;

        assert(checkpoint.key == expected_key, 'Invalid key');
        assert(checkpoint.value == expected_value, 'Invalid value');
    }
}
