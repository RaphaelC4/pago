// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal read-only surface of a TapeOut processor (an ERC-721 `Circuits` contract).
/// Selectors verified live on X Layer mainnet (see docs/RESEARCH.md):
///   nextId()        -> 0x61b8ce8c
///   circuitInfo(id) -> 0x084d60f1
///   eval(id, bytes) -> confirmed by call: eval(uint256,bytes) returns (bytes)
interface IRuleProcessor {
    /// @notice Runs a taped-out circuit gate by gate. Read-only.
    /// @param circuitId The circuit's id within this processor (starts at 1).
    /// @param inputs LSB-first packed input bits, ceil(nIn/8) bytes.
    function eval(uint256 circuitId, bytes calldata inputs) external view returns (bytes memory);

    /// @notice Shape of a circuit. Reverts for an id that does not exist.
    function circuitInfo(uint256 circuitId)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);

    /// @notice The id the next taped-out circuit will get.
    function nextId() external view returns (uint256);

    /// @notice The raw TAP-02 netlist bytes for a circuit (concatenated
    ///         records, no header). Verified live on X Layer mainnet.
    function netlist(uint256 circuitId) external view returns (bytes memory);
}
