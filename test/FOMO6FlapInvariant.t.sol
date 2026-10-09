// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FlapMockToken, FlapMockVaultPortal, FlapMockProcessor} from "./FOMO6Flap.t.sol";
import {FOMO6ForceBNB} from "./helpers/FOMO6Mocks.sol";

contract FOMO6FlapVaultHandler is Test {
    FOMO6FlapVault public game;
    FlapMockToken public token;
    uint256 public count;
    uint256 public modelDeadline;
    address public last;
    address public winner;
    bool public settled;
    bool public claimed;
    uint256 public preTaxes;
    uint256 public postTaxes;
    uint256 public prizePaid;
    uint256 public postPaid;
    uint256 public forced;
    address public immutable PROCESSOR;
    address public constant RECIPIENT = address(0xFEE);
    address public constant PAYOUT = address(0xCAFE);

    constructor(FOMO6FlapVault g, FlapMockToken t, address processor) {
        PROCESSOR = processor;
        game = g;
        token = t;
    }

    function entry(uint256 seed) external {
        address player = address(uint160(0x100000 + seed % 10000));
        token.mint(player, 20_000 ether);
        vm.startPrank(player);
        token.approve(address(game), 20_000 ether);
        (bool ok,) = address(game).call(abi.encodeCall(game.enter, ()));
        vm.stopPrank();
        bool expected = !settled && (modelDeadline == 0 || block.timestamp < modelDeadline);
        assertEq(ok, expected);
        if (ok) {
            uint256 cap = block.timestamp + 21600;
            modelDeadline = modelDeadline == 0 ? cap : (modelDeadline + 30 < cap ? modelDeadline + 30 : cap);
            last = player;
            count++;
        }
    }

    function advance(uint256 delta) external {
        vm.warp(block.timestamp + delta % 21601);
    }

    function tax(uint96 seed) external {
        uint256 amount = uint256(seed) % 1 ether;
        vm.deal(PROCESSOR, amount);
        vm.prank(PROCESSOR);
        (bool ok,) = address(game).call{value: amount}("");
        assertTrue(ok);
        if (settled) postTaxes += amount;
        else preTaxes += amount;
    }

    function force(uint96 seed) external {
        uint256 amount = uint256(seed) % 1 ether;
        vm.deal(address(this), amount);
        new FOMO6ForceBNB{value: amount}(payable(address(game)));
        forced += amount;
    }

    function settle() external {
        (bool ok,) = address(game).call(abi.encodeCall(game.settle, ()));
        bool expected = !settled && modelDeadline != 0 && block.timestamp >= modelDeadline;
        assertEq(ok, expected);
        if (ok) {
            settled = true;
            winner = last;
        }
    }

    function claim(bool authorized) external {
        address caller = authorized && winner != address(0) ? winner : address(this);
        vm.prank(caller);
        (bool ok,) = address(game).call(abi.encodeCall(game.claim, ()));
        bool expected = settled && !claimed && caller == winner;
        assertEq(ok, expected);
        if (ok) {
            claimed = true;
            prizePaid = preTaxes;
        }
    }

    function forward() external {
        game.withdrawPostSettlementTaxes();
        postPaid = postTaxes;
    }

    function wrongBNB(uint96 seed) external {
        uint256 amount = uint256(seed) % 1 ether;
        vm.deal(address(this), amount);
        (bool ok,) = address(game).call{value: amount}("");
        assertFalse(ok);
    }
}

contract FOMO6FlapVaultInvariant is StdInvariant, Test {
    FOMO6FlapVault g;
    FlapMockToken t;
    FOMO6FlapVaultHandler h;

    function setUp() public {
        vm.warp(1000);
        vm.chainId(97);
        address vp = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        FlapMockVaultPortal mock = new FlapMockVaultPortal();
        vm.etch(vp, address(mock).code);
        FOMO6FlapFactory f = new FOMO6FlapFactory(address(0xFEE));
        FlapMockProcessor processor;
        (t, g, processor) = FlapMockVaultPortal(vp).launch(f, bytes32(uint256(1)), 0);
        g.bindTaxProcessor();
        h = new FOMO6FlapVaultHandler(g, t, address(processor));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = h.entry.selector;
        selectors[1] = h.advance.selector;
        selectors[2] = h.tax.selector;
        selectors[3] = h.force.selector;
        selectors[4] = h.settle.selector;
        selectors[5] = h.claim.selector;
        selectors[6] = h.forward.selector;
        selectors[7] = h.wrongBNB.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: selectors}));
        targetContract(address(h));
    }

    function invariantAccountingStateAndWinner() public view {
        assertEq(g.entries(), h.count());
        assertEq(t.balanceOf(g.DEAD()), h.count() * 20_000 ether);
        assertEq(t.balanceOf(address(g)), 0);
        assertEq(g.deadline(), h.modelDeadline());
        assertEq(g.lastPlayer(), h.last());
        assertEq(g.winner(), h.winner());
        assertEq(g.settled(), h.settled());
        assertEq(g.claimed(), h.claimed());
        assertEq(g.jackpot() + h.prizePaid(), h.preTaxes());
        assertEq(g.postSettlementTaxes() + h.postPaid(), h.postTaxes());
        assertEq(g.totalTaxesReceived(), h.preTaxes() + h.postTaxes());
        assertEq(g.prizeAtSettlement(), h.settled() ? h.preTaxes() : 0);
        assertEq(address(g).balance, g.jackpot() + g.postSettlementTaxes() + h.forced());
        assertEq(address(0xFEE).balance, h.postPaid());
        if (h.winner() != address(0)) assertEq(h.winner().balance, h.prizePaid());
        uint256 state = h.settled() ? 3 : (h.modelDeadline() == 0 ? 0 : (block.timestamp < h.modelDeadline() ? 1 : 2));
        assertEq(uint256(g.state()), state);
        if (state == 1) assertLe(g.deadline() - block.timestamp, 21600);
    }

    function afterInvariant() public {
        if (h.count() == 0) h.entry(0);
        if (!g.settled()) {
            vm.warp(g.deadline());
            h.settle();
        }
        if (!g.claimed()) h.claim(true);
        h.forward();
        assertEq(g.jackpot(), 0);
        assertEq(g.postSettlementTaxes(), 0);
        assertEq(address(g).balance, h.forced());
    }
}
