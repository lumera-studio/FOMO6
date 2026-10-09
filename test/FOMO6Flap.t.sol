// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {PackedFeeConfig} from "../src/flap/ITaxProcessor.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";
import {FOMO6ForceBNB, FOMO6MockToken} from "./helpers/FOMO6Mocks.sol";

contract FlapMockToken {
    uint8 public decimals = 18;
    address public taxProcessor;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function initialize(address p) external {
        require(taxProcessor == address(0));
        taxProcessor = p;
    }

    function overrideProcessor(address p) external {
        taxProcessor = p;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function mint(address a, uint256 n) external {
        balanceOf[a] += n;
    }

    function approve(address a, uint256 n) external returns (bool) {
        allowance[msg.sender][a] = n;
        return true;
    }

    function transferFrom(address a, address b, uint256 n) external returns (bool) {
        if (allowance[a][msg.sender] != type(uint256).max) allowance[a][msg.sender] -= n;
        balanceOf[a] -= n;
        balanceOf[b] += n;
        return true;
    }
}

contract FlapMockProcessor {
    address public taxToken;
    address public marketAddress;
    address public constant weth = address(0xBB);
    address public quote = weth;
    bool public native = true;

    constructor(address t, address m) {
        taxToken = t;
        marketAddress = m;
    }

    function getQuoteToken() external view returns (address) {
        return quote;
    }

    function feeConfig() external view returns (PackedFeeConfig memory) {
        return PackedFeeConfig(10000, 0, 0, 0, 0, native);
    }

    function corrupt(address t, address m, address q, bool n) external {
        taxToken = t;
        marketAddress = m;
        quote = q;
        native = n;
    }

    function dispatch() external payable {
        (bool ok,) = marketAddress.call{value: msg.value}("");
        require(ok, "Dispatch failed");
    }
}

contract FlapMockVaultPortal {
    function launch(FOMO6FlapFactory f, bytes32 salt, uint256 earlyTax)
        external
        payable
        returns (FlapMockToken t, FOMO6FlapVault v, FlapMockProcessor p)
    {
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(type(FlapMockToken).creationCode))
                    )
                )
            )
        );
        v = FOMO6FlapVault(payable(f.newVault(predicted, address(0), msg.sender, "")));
        p = new FlapMockProcessor(predicted, address(v));
        if (earlyTax != 0) p.dispatch{value: earlyTax}();
        t = new FlapMockToken{salt: salt}();
        t.initialize(address(p));
    }
}

contract FlapAdversarialWinner {
    FOMO6FlapVault public game;
    bool public reject;
    uint256 public blocked;

    constructor(FOMO6FlapVault g) {
        game = g;
    }

    function configure(bool r) external {
        reject = r;
    }

    function enter(FlapMockToken t) external {
        t.approve(address(game), type(uint256).max);
        game.enter();
    }

    function claim(address payable recipient) external {
        game.claim(recipient);
    }

    receive() external payable {
        require(!reject);
        (bool a,) = address(game).call(abi.encodeCall(game.claim, (payable(address(this)))));
        (bool b,) = address(game).call(abi.encodeCall(game.settle, ()));
        (bool c,) = address(game).call(abi.encodeCall(game.bindTaxProcessor, ()));
        (bool d,) = address(game).call(abi.encodeCall(game.enter, ()));
        (bool e,) = address(game).call(abi.encodeCall(game.withdrawPostSettlementTaxes, ()));
        require(!a && !b && !c && !d && !e);
        blocked += 5;
    }
}

contract FOMO6FlapTest is Test {
    address constant VP = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant ALICE = address(0xA11CE);
    address constant FEE = address(0xFEE);
    FOMO6FlapFactory f;
    FOMO6FlapVault g;
    FlapMockToken t;
    FlapMockProcessor p;

    function setUp() public {
        vm.chainId(97);
        vm.warp(1000);
        vm.deal(address(this), 100 ether);
        FlapMockVaultPortal mock = new FlapMockVaultPortal();
        vm.etch(VP, address(mock).code);
        f = new FOMO6FlapFactory(FEE);
        (t, g, p) = FlapMockVaultPortal(VP).launch(f, bytes32(uint256(1)), 0);
    }

    function entry(address a) internal {
        t.mint(a, 20000 ether);
        vm.startPrank(a);
        t.approve(address(g), type(uint256).max);
        g.enter();
        vm.stopPrank();
    }

    function tax(uint256 n) internal {
        p.dispatch{value: n}();
    }

    function testFactoryAuthenticatesPortalAndRejectsQuoteAndParameters() public {
        vm.expectRevert("Only VaultPortal");
        f.newVault(address(123), address(0), ALICE, "");
        vm.startPrank(VP);
        vm.expectRevert("Native BNB only");
        f.newVault(address(123), address(1), ALICE, "");
        vm.expectRevert("No configurable parameters");
        f.newVault(address(123), address(0), ALICE, hex"01");
        vm.stopPrank();
        assertEq(f.vaultForToken(address(t)), address(g));
        assertTrue(f.isQuoteTokenSupported(address(0)));
        assertFalse(f.isQuoteTokenSupported(address(1)));
    }

    function testEarlyTaxBeforeTokenExistsIsNotLost() public {
        (FlapMockToken tt, FOMO6FlapVault gg, FlapMockProcessor pp) =
            FlapMockVaultPortal(VP).launch{value: 1 ether}(f, bytes32(uint256(2)), 1 ether);
        assertEq(gg.jackpot(), 0);
        assertEq(gg.pendingBySource(address(pp)), 1 ether);
        assertEq(gg.deadline(), 0);
        gg.bindTaxProcessor();
        assertEq(gg.taxProcessor(), address(pp));
        assertEq(address(gg.token()), address(tt));
        assertEq(gg.pendingBySource(address(pp)), 0);
        assertEq(gg.jackpot(), 1 ether);
        assertEq(gg.totalTaxesReceived(), 1 ether);
        assertEq(gg.deadline(), 0);
    }

    function testFirstEntryBindsAndStartsClockWithoutAdmin() public {
        tax(2 ether);
        entry(ALICE);
        assertEq(g.taxProcessor(), address(p));
        assertEq(g.jackpot(), 2 ether);
        assertEq(g.deadline(), 22600);
        vm.warp(1100);
        entry(address(0xB0B));
        assertEq(g.deadline(), 22630);
    }

    function testWrongSourceBeforeBindingAndForcedBNBNeverBecomeJackpot() public {
        (bool ok,) = address(g).call{value: 3 ether}("");
        assertTrue(ok);
        new FOMO6ForceBNB{value: 4 ether}(payable(address(g)));
        tax(2 ether);
        g.bindTaxProcessor();
        assertEq(g.pendingBySource(address(this)), 3 ether);
        assertEq(g.jackpot(), 2 ether);
        assertEq(g.totalTaxesReceived(), 2 ether);
        assertEq(address(g).balance, 9 ether);
        (ok,) = address(g).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function testBindingRejectsWrongLinksNativeModeQuoteAndDecimals() public {
        p.corrupt(address(1), address(g), p.weth(), true);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        p.corrupt(address(t), address(1), p.weth(), true);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        p.corrupt(address(t), address(g), p.weth(), false);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        p.corrupt(address(t), address(g), address(2), true);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        p.corrupt(address(t), address(g), p.weth(), true);
        t.setDecimals(6);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        assertEq(g.taxProcessor(), address(0));
    }

    function testBindingCannotBeReplacedEvenIfTokenGetterChanges() public {
        g.bindTaxProcessor();
        FlapMockProcessor other = new FlapMockProcessor(address(t), address(g));
        t.overrideProcessor(address(other));
        g.bindTaxProcessor();
        assertEq(g.taxProcessor(), address(p));
        tax(1 ether);
        vm.expectRevert("Dispatch failed");
        other.dispatch{value: 1 ether}();
        assertEq(g.jackpot(), 1 ether);
    }

    function testDispatchSettlementClaimAndLaterTax() public {
        tax(1 ether);
        entry(ALICE);
        vm.warp(g.deadline());
        tax(2 ether);
        g.settle();
        tax(3 ether);
        assertEq(g.winner(), ALICE);
        assertEq(g.prizeAtSettlement(), 3 ether);
        assertEq(g.postSettlementTaxes(), 3 ether);
        vm.prank(ALICE);
        g.claim(payable(ALICE));
        g.withdrawPostSettlementTaxes();
        assertEq(ALICE.balance, 3 ether);
        assertEq(FEE.balance, 3 ether);
        vm.expectRevert(FOMO6FlapVault.AlreadySettled.selector);
        g.settle();
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.AlreadyClaimed.selector);
        g.claim(payable(ALICE));
    }

    function testReceiveGasBeforeAndAfterBindingBelowOfficialBudget() public {
        uint256 start = gasleft();
        tax(1 ether);
        assertLt(start - gasleft(), 1000000);
        g.bindTaxProcessor();
        start = gasleft();
        tax(1 ether);
        assertLt(start - gasleft(), 1000000);
    }

    function testZeroWakeAndMetadata() public {
        (bool ok,) = address(g).call("");
        assertTrue(ok);
        assertEq(g.pendingBySource(address(this)), 0);
        assertGt(bytes(g.description()).length, 0);
        assertEq(g.vaultUISchema().vaultType, "FOMO6");
        assertEq(f.vaultDataSchema().fields.length, 0);
    }

    function testMaliciousWinnerReentrancyAndFailedClaimRetry() public {
        FlapAdversarialWinner winner = new FlapAdversarialWinner(g);
        t.mint(address(winner), 20000 ether);
        winner.enter(t);
        tax(1 ether);
        vm.warp(g.deadline());
        g.settle();
        winner.configure(true);
        vm.expectRevert(FOMO6FlapVault.TransferFailed.selector);
        winner.claim(payable(address(winner)));
        assertFalse(g.claimed());
        assertEq(g.jackpot(), 1 ether);
        winner.configure(false);
        winner.claim(payable(address(winner)));
        assertEq(winner.blocked(), 5);
        assertEq(address(winner).balance, 1 ether);
    }

    function mass(uint256 n) internal {
        g.bindTaxProcessor();
        uint256 expected;
        address last;
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 5);
            last = address(uint160(0x100000 + i));
            entry(last);
            tax(0.001 ether);
            uint256 cap = block.timestamp + 21600;
            expected = i == 0 ? cap : (expected + 30 < cap ? expected + 30 : cap);
            assertEq(g.deadline(), expected);
        }
        assertEq(g.jackpot(), n * 0.001 ether);
        assertEq(t.balanceOf(g.DEAD()), n * 20000 ether);
        vm.warp(g.deadline());
        g.settle();
        assertEq(g.winner(), last);
        vm.prank(last);
        g.claim(payable(ALICE));
        assertEq(ALICE.balance, n * 0.001 ether);
    }

    function test100Entries() public {
        mass(100);
    }

    function test1000Entries() public {
        mass(1000);
    }

    function test10000Entries() public {
        mass(10000);
    }

    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    function testEmergencyOnlyGuardianNotDeployerOrPlayer() public {
        vm.expectRevert("Only Guardian");
        g.emergencyWithdrawNative(ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert("Only Guardian");
        g.emergencyWithdrawNative(ALICE);
        vm.expectRevert("Only Guardian");
        g.emergencyWithdrawToken(address(t), ALICE);
        vm.stopPrank();
        assertFalse(g.emergencyStopped());
    }

    function testEmergencyBeforeBindingIncludesPendingAndForcedFunds() public {
        tax(2 ether);
        new FOMO6ForceBNB{value: 1 ether}(payable(address(g)));
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(ALICE);
        assertEq(ALICE.balance, 3 ether);
        assertTrue(g.emergencyStopped());
        assertEq(g.totalEmergencyWithdrawn(), 3 ether);
        assertEq(uint256(g.state()), 4);
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.bindTaxProcessor();
    }

    function testEmergencyStopsActiveGameAndDoesNotExposeFalsePrize() public {
        entry(ALICE);
        tax(1 ether);
        uint256 old = g.deadline();
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(address(0xCAFE));
        assertEq(g.jackpotAtEmergency(), 1 ether);
        assertEq(g.jackpot(), 0);
        assertEq(g.deadline(), old);
        assertEq(g.lastPlayer(), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.enter();
        vm.warp(old);
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.settle();
    }

    function testEmergencyMayRemoveUnclaimedPrizeAndPreservesHistory() public {
        entry(ALICE);
        tax(1 ether);
        vm.warp(g.deadline());
        g.settle();
        tax(2 ether);
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(address(0xCAFE));
        assertEq(g.winner(), ALICE);
        assertEq(g.prizeAtSettlement(), 1 ether);
        assertEq(g.jackpotAtEmergency(), 1 ether);
        assertEq(g.postTaxesAtEmergency(), 2 ether);
        assertEq(g.jackpot(), 0);
        assertEq(g.postSettlementTaxes(), 0);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.claim(payable(ALICE));
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.withdrawPostSettlementTaxes();
    }

    function testEmergencyFailedDestinationRollsBackStopAndAccounting() public {
        FlapAdversarialWinner reject = new FlapAdversarialWinner(g);
        reject.configure(true);
        entry(ALICE);
        tax(1 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(FOMO6FlapVault.TransferFailed.selector);
        g.emergencyWithdrawNative(address(reject));
        assertFalse(g.emergencyStopped());
        assertEq(g.jackpot(), 1 ether);
        assertEq(g.totalEmergencyWithdrawn(), 0);
    }

    function testLaterTaxAfterEmergencyStillReceivesAndCanBeRecovered() public {
        g.bindTaxProcessor();
        tax(1 ether);
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(ALICE);
        tax(2 ether);
        assertEq(g.emergencyReceipts(), 2 ether);
        assertEq(g.jackpot(), 0);
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(ALICE);
        assertEq(ALICE.balance, 3 ether);
        assertEq(g.totalEmergencyWithdrawn(), 3 ether);
    }

    function testEmergencyPayoutReentrancyBlocked() public {
        FlapAdversarialWinner receiver = new FlapAdversarialWinner(g);
        entry(ALICE);
        tax(1 ether);
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(address(receiver));
        assertEq(receiver.blocked(), 5);
        assertTrue(g.emergencyStopped());
    }

    function testEmergencyInvalidDestinationDoesNotStopRound() public {
        vm.startPrank(GUARDIAN);
        vm.expectRevert("Invalid emergency destination");
        g.emergencyWithdrawNative(address(0));
        vm.expectRevert("Invalid emergency destination");
        g.emergencyWithdrawNative(address(g));
        vm.stopPrank();
        assertFalse(g.emergencyStopped());
    }

    function testEmergencyTokenRecoveryDoesNotSpendPlayerAllowanceOrJackpot() public {
        FOMO6MockToken held = new FOMO6MockToken();
        held.mint(address(g), 777 ether);
        entry(ALICE);
        tax(1 ether);
        uint256 oldAllowance = t.allowance(ALICE, address(g));
        vm.prank(GUARDIAN);
        g.emergencyWithdrawToken(address(held), ALICE);
        assertEq(held.balanceOf(ALICE), 777 ether);
        assertEq(held.balanceOf(address(g)), 0);
        assertEq(t.allowance(ALICE, address(g)), oldAllowance);
        assertEq(g.jackpot(), 1 ether);
        assertFalse(g.emergencyStopped());
    }

    function validData() internal pure returns (IVaultFactoryValidationV2.LaunchValidationDataV1 memory d) {
        d.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        d.buyTaxRate = 300;
        d.sellTaxRate = 300;
        d.vaultBps = 10000;
    }

    function testLaunchValidation() public {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d = validData();
        (bool ok,) = f.onBeforeLaunch(abi.encode(d));
        assertTrue(ok);
        d.sellTaxRate = 1000;
        (ok,) = f.onBeforeLaunch(abi.encode(d));
        assertFalse(ok);
        d = validData();
        d.dividendBps = 1;
        (ok,) = f.onBeforeLaunch(abi.encode(d));
        assertFalse(ok);
    }

    function testFuzzPendingClassification(uint96 a, uint96 b) public {
        uint256 n = uint256(a) % 10 ether;
        uint256 extra = uint256(b) % 10 ether;
        (bool ok,) = address(g).call{value: extra}("");
        assertTrue(ok);
        tax(n);
        g.bindTaxProcessor();
        assertEq(g.jackpot(), n);
        assertEq(g.pendingBySource(address(this)), extra);
        assertEq(address(g).balance, n + extra);
    }
}
