// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {PackedFeeConfig} from "../src/flap/ITaxProcessor.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {IPortalTypes} from "../src/flap/IPortal.sol";

contract FlapMockToken {
    uint8 public decimals = 18;
    address public taxProcessor;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public transferMode;

    function setTransferMode(uint256 mode) external {
        transferMode = mode;
    }

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
        balanceOf[b] += transferMode == 1 ? n - 1 : n;
        if (transferMode == 2) return false;
        return true;
    }
}

contract FlapMockProcessor {
    address public taxToken;
    address public marketAddress;
    address public constant weth = address(0xBB);
    address public quote = weth;
    bool public native = true;
    bool public failDispatch;
    bool public attackDispatch;
    uint256 public blockedCallbacks;

    function configureDispatch(bool fail, bool attack) external {
        failDispatch = fail;
        attackDispatch = attack;
    }

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
        require(!failDispatch, "Processor failure");
        if (attackDispatch) {
            (bool recursive,) = marketAddress.call(abi.encodeWithSignature("collectTaxes()"));
            (bool settlement,) = marketAddress.call(abi.encodeWithSignature("settle()"));
            require(!recursive && !settlement, "Unsafe callback");
            blockedCallbacks += 2;
        }
        (bool ok,) = marketAddress.call{value: address(this).balance}("");
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

contract ForcedBNB {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

contract ReentrantWinner {
    FOMO6FlapVault g;
    uint256 public blocked;

    constructor(FOMO6FlapVault game) {
        g = game;
    }

    function enter(FlapMockToken t) external {
        t.approve(address(g), type(uint256).max);
        g.enter();
    }

    function claim(uint256 id) external {
        g.claim(id);
    }

    receive() external payable {
        (bool a,) = address(g).call(abi.encodeCall(g.enter, ()));
        (bool b,) = address(g).call(abi.encodeCall(g.settle, ()));
        (bool c,) = address(g).call(abi.encodeCall(g.claim, (uint256(1))));
        require(!a && !b && !c);
        blocked += 3;
    }
}

contract FOMO6FlapTest is Test {
    address constant VP = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
    FOMO6FlapFactory f;
    FOMO6FlapVault g;
    FlapMockToken t;
    FlapMockProcessor p;

    function setUp() public {
        vm.chainId(97);
        vm.warp(1000);
        vm.deal(address(this), 100000 ether);
        FlapMockVaultPortal mock = new FlapMockVaultPortal();
        vm.etch(VP, address(mock).code);
        f = new FOMO6FlapFactory();
        (t, g, p) = FlapMockVaultPortal(VP).launch(f, bytes32(uint256(1)), 0);
    }

    function entry(address who) internal {
        t.mint(who, 20000 ether);
        vm.startPrank(who);
        t.approve(address(g), type(uint256).max);
        g.enter();
        vm.stopPrank();
    }

    function tax(uint256 n) internal {
        p.dispatch{value: n}();
    }

    function testWaitingTaxAndFirstEntry() public {
        tax(1 ether);
        assertEq(g.deadline(), 0);
        entry(ALICE);
        assertEq(g.jackpot(), 1 ether);
        assertEq(g.deadline(), 22600);
    }

    function testTimerExtensionCapAndSameBlock() public {
        entry(ALICE);
        entry(BOB);
        assertEq(g.deadline(), 22600);
        vm.warp(2000);
        entry(ALICE);
        assertEq(g.deadline(), 22720);
        assertEq(g.lastPlayer(), ALICE);
    }

    function testBoundaryBeforeAndAtDeadline() public {
        entry(ALICE);
        vm.warp(g.deadline() - 1);
        entry(BOB);
        vm.warp(g.deadline());
        vm.expectRevert(FOMO6FlapVault.GameEnded.selector);
        vm.prank(ALICE);
        g.enter();
        g.settle();
        assertEq(g.winnerOf(1), BOB);
    }

    function testExpiredReceiptFundsNextRound() public {
        entry(ALICE);
        tax(1 ether);
        vm.warp(g.deadline());
        tax(2 ether);
        assertEq(g.prizeOf(1), 1 ether);
        assertEq(ALICE.balance, 1 ether);
        assertEq(g.jackpot(), 2 ether);
        assertEq(g.roundId(), 2);
        assertEq(g.deadline(), 0);
        entry(BOB);
        assertEq(g.deadline(), block.timestamp + 21600);
        vm.warp(g.deadline());
        g.settle();
        assertEq(BOB.balance, 2 ether);
    }

    function testRejectedWinnerIndependentFromNextRoundAndRetry() public {
        entry(ALICE);
        tax(1 ether);
        vm.etch(ALICE, hex"60006000fd");
        vm.warp(g.deadline());
        tax(2 ether);
        assertFalse(g.claimedOf(1));
        assertEq(g.outstandingPrizes(), 1 ether);
        entry(BOB);
        vm.warp(g.deadline());
        g.settle();
        assertEq(BOB.balance, 2 ether);
        assertEq(address(g).balance, 1 ether);
        vm.etch(ALICE, hex"");
        vm.prank(ALICE);
        g.claim(1);
        assertEq(ALICE.balance, 1 ether);
        assertEq(g.outstandingPrizes(), 0);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.AlreadyClaimed.selector);
        g.claim(1);
    }

    function testNoDoubleSettlementAndNoEmptyRounds() public {
        entry(ALICE);
        vm.warp(g.deadline());
        g.settle();
        vm.expectRevert(FOMO6FlapVault.NotEnded.selector);
        g.settle();
        tax(1 ether);
        assertEq(g.roundId(), 2);
        assertEq(g.deadline(), 0);
    }

    function testClaimsCannotRedirectOrSteal() public {
        entry(ALICE);
        tax(1 ether);
        vm.etch(ALICE, hex"60006000fd");
        vm.warp(g.deadline());
        g.settle();
        vm.prank(BOB);
        vm.expectRevert(FOMO6FlapVault.NotWinner.selector);
        g.claim(1);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.TransferFailed.selector);
        g.claim(1);
        assertEq(g.outstandingPrizes(), 1 ether);
        vm.expectRevert(FOMO6FlapVault.NotSettled.selector);
        g.claim(2);
    }

    function testWrongBNBAndForcedAccounting() public {
        g.bindTaxProcessor();
        vm.expectRevert(FOMO6FlapVault.UnauthorizedTaxSource.selector);
        (bool ok,) = address(g).call{value: 1 ether}("");
        ok;
        new ForcedBNB{value: 2 ether}(payable(address(g)));
        assertEq(g.jackpot(), 0);
        assertEq(g.deadline(), 0);
        assertEq(address(g).balance, 2 ether);
    }

    function testNoEntryApprovalAndWrongMsgValue() public {
        t.mint(ALICE, 20000 ether);
        vm.prank(ALICE);
        vm.expectRevert();
        g.enter();
        vm.prank(ALICE);
        vm.deal(ALICE, 1 ether);
        (bool ok,) = address(g).call{value: 1}(abi.encodeCall(g.enter, ()));
        assertFalse(ok);
        assertEq(g.entries(), 0);
    }

    function testBindingCannotBeChanged() public {
        g.bindTaxProcessor();
        FlapMockProcessor other = new FlapMockProcessor(address(t), address(g));
        t.overrideProcessor(address(other));
        g.bindTaxProcessor();
        assertEq(g.taxProcessor(), address(p));
    }

    function testInvalidProcessorAndFactoryCaller() public {
        p.corrupt(address(1), address(g), p.weth(), true);
        vm.expectRevert(FOMO6FlapVault.InvalidTaxProcessor.selector);
        g.bindTaxProcessor();
        vm.expectRevert("Only VaultPortal");
        f.newVault(address(1), address(0), ALICE, "");
    }

    function testGuardianStopsAllRoundClaims() public {
        entry(ALICE);
        tax(1 ether);
        vm.etch(ALICE, hex"60006000fd");
        vm.warp(g.deadline());
        g.settle();
        tax(2 ether);
        vm.expectRevert("Only Guardian");
        g.emergencyWithdrawNative(BOB);
        vm.prank(GUARDIAN);
        g.emergencyWithdrawNative(BOB);
        assertEq(BOB.balance, 3 ether);
        assertTrue(g.emergencyStopped());
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.EmergencyStopped.selector);
        g.claim(1);
    }

    function testMaliciousWinnerCannotReenterOrBlockNewRound() public {
        ReentrantWinner w = new ReentrantWinner(g);
        t.mint(address(w), 20000 ether);
        w.enter(t);
        tax(1 ether);
        vm.warp(g.deadline());
        g.settle();
        if (!g.claimedOf(1)) w.claim(1);
        assertEq(address(w).balance, 1 ether);
        assertEq(w.blocked(), 3);
        entry(BOB);
        assertEq(g.roundId(), 2);
    }

    function testPartialAndFailedTokenTransfersRollback() public {
        t.mint(ALICE, 20000 ether);
        vm.prank(ALICE);
        t.approve(address(g), type(uint256).max);
        t.setTransferMode(1);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.WrongTokenAmount.selector);
        g.enter();
        assertEq(t.balanceOf(ALICE), 20000 ether);
        assertEq(g.deadline(), 0);
        t.setTransferMode(2);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.TokenTransferFailed.selector);
        g.enter();
        assertEq(g.entries(), 0);
    }

    function testEarlyReceiptsOnlyVerifiedSourceCredited() public {
        tax(1 ether);
        (bool ok,) = address(g).call{value: 2 ether}("");
        assertTrue(ok);
        entry(ALICE);
        assertEq(g.jackpot(), 1 ether);
        assertEq(g.totalTaxesReceived(), 1 ether);
        assertEq(g.pendingBySource(address(this)), 2 ether);
    }

    function testManyUnpaidRoundsRemainIndependent() public {
        vm.etch(ALICE, hex"60006000fd");
        for (uint256 i = 1; i <= 20; ++i) {
            entry(ALICE);
            tax(0.01 ether);
            vm.warp(g.deadline());
            g.settle();
            assertEq(g.prizeOf(i), 0.01 ether);
            assertFalse(g.claimedOf(i));
        }
        assertEq(g.outstandingPrizes(), 0.2 ether);
        vm.etch(ALICE, hex"");
        for (uint256 i = 20; i > 0; --i) {
            vm.prank(ALICE);
            g.claim(i);
        }
        assertEq(g.outstandingPrizes(), 0);
        assertEq(ALICE.balance, 0.2 ether);
    }

    function mass(uint256 n) internal {
        entry(ALICE);
        uint256 d = g.deadline();
        for (uint256 i = 1; i < n; ++i) {
            vm.warp(block.timestamp + 5);
            address who = address(uint160(0x100000 + i));
            entry(who);
            uint256 cap = block.timestamp + 21600;
            d = d + 120 < cap ? d + 120 : cap;
            assertEq(g.deadline(), d);
        }
        tax(n * 0.001 ether);
        address winner = g.lastPlayer();
        vm.warp(d);
        g.settle();
        assertEq(g.prizeOf(1), n * 0.001 ether);
        assertEq(winner.balance, n * 0.001 ether);
        assertEq(t.balanceOf(g.DEAD()), n * 20000 ether);
        assertEq(g.outstandingPrizes(), 0);
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

    function testFuzzRoundAccounting(uint96 a, uint96 b, uint32 dt) public {
        uint256 x = uint256(a) % 10 ether;
        uint256 y = uint256(b) % 10 ether;
        entry(ALICE);
        tax(x);
        vm.warp(g.deadline() + uint256(dt));
        tax(y);
        assertEq(g.prizeOf(1), x);
        assertEq(ALICE.balance, x);
        assertEq(g.jackpot(), y);
        assertEq(g.totalTaxesReceived(), x + y);
        assertEq(g.deadline(), 0);
    }
}
