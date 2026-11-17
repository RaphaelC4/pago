// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";

/// Phase 0 item: container / name resolution verifiability.
///
/// `0x536adD8F30f03b69f6fbF29d425A816A0dC50106` is a live contract on X Layer
/// mainnet. Its dispatcher was resolved against the 4byte directory:
///
///     open(address,uint256)          0x0a0e5c9d
///     accountOf(address,uint256)     0x0c1905e5
///     isDeployed(address,uint256)    0xf13906b8
///     FEE()                          0xc57981b5   -> 8e16 wei
///     SALT()                         0xba9a91a5   -> 0
///     treasury()                     0x61d027b3
///     payments()                     0xa6d23e10
///     registry()                     0x7b103999
///     implementation()               0x5c60da1b
///
/// Decoding `open`'s bytecode showed its first action is
/// `factory.isCPU(addr)` (selector `0x5f5a364f`); if that returns false it
/// reverts with the custom error `0x5c69a867`. So the first argument is a
/// **processor** address, not an arbitrary owner, and the fee check is
/// `msg.value >= FEE()`.
///
/// The question Phase 0 had to answer: can a container address be *predicted*
/// before it exists? If yes, a payment link can be published before any gas is
/// spent, and anyone can check the target address is the one they expect.
interface IContainer {
    function open(address, uint256) external payable returns (address);
    function accountOf(address, uint256) external view returns (address);
    function isDeployed(address, uint256) external view returns (bool);
    function FEE() external view returns (uint256);
    function SALT() external view returns (uint256);
    function treasury() external view returns (address);
    function payments() external view returns (address);
}

interface IFactoryIsCPU {
    function isCPU(address) external view returns (bool);
}

contract ContainerResolutionTest is Test {
    address constant CONTAINER = 0x536adD8F30f03b69f6fbF29d425A816A0dC50106;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    /// Processor #340, which holds a known circuit (see DemoCircuits.t.sol).
    address constant CPU_340 = 0x9de448A1CE9537d24199B3b5355239d73aA6F591;

    address alice;

    function setUp() public {
        vm.createSelectFork(vm.envString("XLAYER_RPC"));
        (alice,) = makeAddrAndKey("alice");
    }

    /// Fees and wiring are read live rather than hard-coded.
    function test_containerWiringIsReadable() public view {
        IContainer c = IContainer(CONTAINER);
        assertEq(c.FEE(), 8e16, "FEE");
        assertEq(c.SALT(), 0, "SALT");
        assertTrue(c.treasury() != address(0), "treasury");
        assertTrue(c.payments() != address(0), "payments");
        console.log("FEE", c.FEE());
        console.log("treasury", c.treasury());
        console.log("payments", c.payments());
    }

    /// `open` only accepts a real processor. An EOA must be refused.
    function test_openRejectsANonProcessor() public {
        IContainer c = IContainer(CONTAINER);
        assertFalse(IFactoryIsCPU(FACTORY).isCPU(alice), "alice must not be a processor");

        // The fee must be read *before* expectRevert: an external call inside
        // the value expression would otherwise consume the expectation.
        uint256 fee = c.FEE();
        address predicted = c.accountOf(alice, 1);
        uint256 codeBefore = predicted.code.length;

        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(bytes4(0x5c69a867));
        c.open{value: fee}(alice, 1);

        assertEq(predicted.code.length, codeBefore, "nothing may have been deployed");
    }

    /// The container address is deterministic and readable *before* it exists,
    /// for a processor address as well as for an arbitrary one.
    function test_accountIsPredictableBeforeDeployment() public {
        IContainer c = IContainer(CONTAINER);
        address p0 = c.accountOf(CPU_340, 0);
        address p1 = c.accountOf(CPU_340, 1);
        assertTrue(p0 != address(0), "must predict id 0");
        assertTrue(p1 != address(0), "must predict id 1");
        assertTrue(p0 != p1, "different ids, different addresses");
        assertTrue(c.accountOf(alice, 0) != p0, "different owner, different address");
        console.log("predicted(CPU_340,0)", p0);
        console.log("predicted(CPU_340,1)", p1);
    }

    /// `isDeployed` must agree with the chain's actual code at the predicted
    /// address -- that is what makes the prediction trustworthy.
    function test_isDeployedAgreesWithActualCode() public {
        IContainer c = IContainer(CONTAINER);
        for (uint256 id; id < 4; ++id) {
            address predicted = c.accountOf(CPU_340, id);
            assertEq(c.isDeployed(CPU_340, id), predicted.code.length > 0, "isDeployed disagrees with code");
            // and the same for an address that is not a processor
            address other = c.accountOf(alice, id);
            assertEq(c.isDeployed(alice, id), other.code.length > 0, "isDeployed disagrees with code (2)");
        }
    }

    /// Called without the fee, `open` must revert rather than silently deploy.
    function test_openRequiresTheFee() public {
        IContainer c = IContainer(CONTAINER);
        address predicted = c.accountOf(CPU_340, 1);
        uint256 before = predicted.code.length;

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        c.open{value: 0}(CPU_340, 1);

        assertEq(predicted.code.length, before, "nothing may have been deployed");
        assertFalse(c.isDeployed(CPU_340, 1), "still not deployed");
    }

    /// The circuit must actually exist: `open` resolves it as an ERC721 token on
    /// the processor's circuits contract and reverts if it does not.
    function test_openRejectsAMissingCircuit() public {
        IContainer c = IContainer(CONTAINER);
        uint256 fee = c.FEE(); // read before expectRevert
        // Circuit #1 exists on processor #340; #99 does not.
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", uint256(99)));
        c.open{value: fee}(CPU_340, 99);
        assertFalse(c.isDeployed(CPU_340, 99), "nothing may have been deployed");
    }

    /// Called with the exact fee against a real processor and an existing
    /// circuit, `open` must succeed and the container must appear at the address
    /// predicted beforehand.
    function test_openWithFeeDeploysAtThePredictedAddress() public {
        IContainer c = IContainer(CONTAINER);
        uint256 fee = c.FEE();
        assertTrue(IFactoryIsCPU(FACTORY).isCPU(CPU_340), "CPU_340 must be a processor");

        address predicted = c.accountOf(CPU_340, 1);
        assertEq(predicted.code.length, 0, "must not exist yet");

        vm.deal(alice, fee);
        vm.prank(alice);
        c.open{value: fee}(CPU_340, 1);

        console.log("predicted", predicted);
        assertGt(predicted.code.length, 0, "container must have code at the predicted address");
        assertTrue(c.isDeployed(CPU_340, 1), "isDeployed must now be true");
    }
}
