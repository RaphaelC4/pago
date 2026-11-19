// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockBeacon - the `implementation()` getter rule 6's leg 2 calls.
///
/// Mirrors the shape of the real TapeOut circuit beacon probed on X Layer
/// mainnet (docs/RESEARCH.md section 18): a small contract exposing exactly
/// one public getter, `implementation() -> address`, selector `0x5c60da1b`.
/// The real beacon is frozen (`owner() = 0`); this mock keeps a setter so a
/// test can simulate the beacon reporting a different implementation - the
/// Q4 case where swapping what sits behind the proxy must flip
/// `evaluatorPinned` to false.
contract MockBeacon {
    address public implementation;

    constructor(address implementation_) {
        implementation = implementation_;
    }

    /// Test-only: make the beacon report a different implementation.
    function setImplementation(address implementation_) external {
        implementation = implementation_;
    }
}
