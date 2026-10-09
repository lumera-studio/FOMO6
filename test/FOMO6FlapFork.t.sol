// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {IPortalTypes, IPortalCommonTypes, IPortalTradeV2} from "../src/flap/IPortal.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";

/// @notice Optional real-protocol local fork. No broadcast, keys, or real funds.
contract FOMO6FlapForkTest is Test {
    function testRealProtocolLaunchBuyDispatchEnterSettleClaim() public {
        string memory rpc = vm.envOr("FOMO6_FLAP_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("FOMO6_FLAP_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        emit log_named_uint("Fork block", block.number);
        require(block.chainid == 56, "This fixture uses official BSC mainnet reference addresses, locally only");
        address portal = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
        address vp = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
        FOMO6FlapFactory f = new FOMO6FlapFactory(address(0xFEE));
        // Mined off-chain using viem EIP-1167/CREATE2 formula; no unbounded EVM search.
        bytes32 salt = 0x7b9c7c1c395457e8a3a22ef441c87ec26c085987c4ecadbe468f33407246f793;
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params;
        params.name = "FOMO6 Fork Test";
        params.symbol = "tFOMO6";
        params.salt = salt;
        params.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        params.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        params.dexId = IPortalTypes.DEXId.DEX0;
        params.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        params.buyTaxRate = 300;
        params.sellTaxRate = 300;
        params.taxDuration = uint64(100 * 365 days);
        params.antiFarmerDuration = uint64(1 days);
        params.mktBps = 10000;
        params.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        params.vaultFactory = address(f);
        address alice = address(0xA11CE);
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        address token = IVaultPortal(payable(vp)).newTokenV6WithVault(params);
        FOMO6FlapVault game = FOMO6FlapVault(payable(f.vaultForToken(token)));
        IFlapTaxTokenV3 t = IFlapTaxTokenV3(token);
        address processor = t.taxProcessor();
        assertEq(ITaxProcessor(processor).marketAddress(), address(game));
        assertEq(t.buyTaxRate(), 300);
        assertEq(t.sellTaxRate(), 300);
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        IPortalTradeV2(portal).swapExactInput{value: 0.1 ether}(
            IPortalTradeV2.ExactInputParams(address(0), token, 0.1 ether, 0, "")
        );
        vm.stopPrank();
        ITaxProcessor(processor).dispatch();
        uint256 totalBefore = game.pendingBySource(processor);
        game.bindTaxProcessor();
        assertEq(game.taxProcessor(), processor);
        assertGt(game.jackpot(), 0);
        assertEq(game.jackpot(), totalBefore);
        assertEq(game.deadline(), 0);
        vm.startPrank(alice);
        t.approve(address(game), type(uint256).max);
        game.enter();
        vm.stopPrank();
        assertEq(t.balanceOf(game.DEAD()), 20000 ether);
        assertEq(game.deadline(), block.timestamp + 6 hours);
        vm.warp(game.deadline());
        game.settle();
        uint256 prize = game.jackpot();
        uint256 beforeClaim = alice.balance;
        vm.prank(alice);
        game.claim();
        assertEq(alice.balance, beforeClaim + prize);
        assertEq(game.jackpot(), 0);
        assertTrue(game.claimed());
    }
}
