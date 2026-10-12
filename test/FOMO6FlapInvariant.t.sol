// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FlapMockToken, FlapMockProcessor, FlapMockVaultPortal, ForcedBNB} from "./FOMO6Flap.t.sol";

contract MultiRoundHandler is Test {
    FOMO6FlapVault public g;
    FlapMockToken public t;
    address public p;
    uint256 public taxes;
    uint256 public paid;
    uint256 public forced;
    uint256 public burned;
    uint256 public id = 1;
    uint256 public deadline;
    address public last;
    uint256 public pool;

    constructor(FOMO6FlapVault game, FlapMockToken token, address processor) {
        g = game;
        t = token;
        p = processor;
    }

    function entry(uint256 seed) external {
        address who = address(uint160(0x100000 + seed % 10000));
        t.mint(who, 20000 ether);
        vm.startPrank(who);
        t.approve(address(g), type(uint256).max);
        (bool ok,) = address(g).call(abi.encodeCall(g.enter, ()));
        vm.stopPrank();
        bool expected = deadline == 0 || block.timestamp < deadline;
        assertEq(ok, expected);
        if (ok) {
            uint256 cap = block.timestamp + 21600;
            deadline = deadline == 0 ? cap : (deadline + 120 < cap ? deadline + 120 : cap);
            last = who;
            burned += 20000 ether;
        }
    }

    function advance(uint32 dt) external {
        vm.warp(block.timestamp + uint256(dt) % 21601);
    }

    function tax(uint96 n) external {
        uint256 a = uint256(n) % 1 ether;
        if (deadline != 0 && block.timestamp >= deadline) _modelSettle();
        vm.deal(p, a);
        vm.prank(p);
        (bool ok,) = address(g).call{value: a}("");
        assertTrue(ok);
        taxes += a;
        pool += a;
    }

    function settle() external {
        bool expected = deadline != 0 && block.timestamp >= deadline;
        (bool ok,) = address(g).call(abi.encodeCall(g.settle, ()));
        assertEq(ok, expected);
        if (ok) _modelSettle();
    }

    function _modelSettle() internal {
        assertEq(g.winnerOf(id) == address(0) ? last : g.winnerOf(id), last);
        paid += pool;
        pool = 0;
        id++;
        deadline = 0;
        last = address(0);
    }

    function force(uint96 n) external {
        uint256 a = uint256(n) % 1 ether;
        vm.deal(address(this), a);
        new ForcedBNB{value: a}(payable(address(g)));
        forced += a;
    }
}

contract FOMO6FlapVaultInvariant is StdInvariant, Test {
    FOMO6FlapVault g;
    FlapMockToken t;
    MultiRoundHandler h;

    function setUp() public {
        vm.chainId(97);
        vm.warp(1000);
        address vp = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
        FlapMockVaultPortal m = new FlapMockVaultPortal();
        vm.etch(vp, address(m).code);
        FOMO6FlapFactory f = new FOMO6FlapFactory();
        FlapMockProcessor p;
        (t, g, p) = FlapMockVaultPortal(vp).launch(f, bytes32(uint256(1)), 0);
        g.bindTaxProcessor();
        h = new MultiRoundHandler(g, t, address(p));
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = h.entry.selector;
        sel[1] = h.advance.selector;
        sel[2] = h.tax.selector;
        sel[3] = h.settle.selector;
        sel[4] = h.force.selector;
        targetSelector(FuzzSelector(address(h), sel));
        targetContract(address(h));
    }

    function invariantIndependentAccountingAndRounds() public view {
        assertEq(g.roundId(), h.id());
        assertEq(g.deadline(), h.deadline());
        assertEq(g.lastPlayer(), h.last());
        assertEq(g.jackpot(), h.pool());
        assertEq(g.totalTaxesReceived(), h.taxes());
        assertEq(h.paid() + g.jackpot(), h.taxes());
        assertEq(address(g).balance, g.jackpot() + g.outstandingPrizes() + h.forced());
        assertEq(t.balanceOf(g.DEAD()), h.burned());
        if (g.deadline() > block.timestamp) assertLe(g.deadline() - block.timestamp, 21600);
    }
}
