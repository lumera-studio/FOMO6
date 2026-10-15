// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {Test} from "forge-std/Test.sol";
import {FOMO6FlapFactory} from "../src/FOMO6FlapFactory.sol";
import {FOMO6FlapVault} from "../src/FOMO6FlapVault.sol";
import {IPortalTypes, IPortalCommonTypes, IPortalTradeV2} from "../src/flap/IPortal.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {ITaxProcessor} from "../src/flap/ITaxProcessor.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";

/// @notice Read-only BSC fork; ALL deployments/trades exist locally, never broadcast.
contract FOMO6FlapForkTest is Test {
    address constant PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant VP = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address constant ALICE = address(0xA11CE);
    FOMO6FlapFactory factory;
    FOMO6FlapVault game;
    IFlapTaxTokenV3 token;
    ITaxProcessor processor;

    function setUp() public {
        string memory rpc = vm.envOr("FOMO6_FLAP_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pinned = vm.envOr("FOMO6_FLAP_FORK_BLOCK", uint256(0));
        if (pinned == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pinned);
        require(block.chainid == 56, "BSC local fork only");
        emit log_named_uint("Fork block", block.number);
        factory = new FOMO6FlapFactory();
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params;
        params.name = "FOMO6 Local Fork";
        params.symbol = "tFOMO6";
        params.salt = 0x7b9c7c1c395457e8a3a22ef441c87ec26c085987c4ecadbe468f33407246f793;
        params.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        params.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        params.dexId = IPortalTypes.DEXId.DEX0;
        params.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        params.buyTaxRate = 300;
        params.sellTaxRate = 300;
        // Fixture values only, not final launch settings.
        params.taxDuration = uint64(100 * 365 days);
        params.antiFarmerDuration = uint64(1 days);
        params.mktBps = 10000;
        params.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        params.vaultFactory = address(factory);
        vm.deal(ALICE, 1000 ether);
        vm.prank(ALICE);
        address created = IVaultPortal(payable(VP)).newTokenV6WithVault{gas: 10_000_000}(params);
        token = IFlapTaxTokenV3(created);
        game = FOMO6FlapVault(payable(factory.vaultForToken(created)));
        assertEq(IVaultPortal(payable(VP)).getVault(created).vault, address(game));
        processor = ITaxProcessor(token.taxProcessor());
        assertEq(processor.marketAddress(), address(game));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.buyTaxRate(), 300);
        assertEq(token.sellTaxRate(), 300);
        game.bindTaxProcessor();
        _buy(0.1 ether);
        emit log_named_uint("Vault taxes immediately after curve buy", game.totalTaxesReceived());
        emit log_named_uint("Processor pending after curve buy", processor.marketQuoteBalance());
        _dispatch();
        assertGt(game.jackpot(), 0);
        assertEq(game.deadline(), 0);
        vm.prank(ALICE);
        token.approve(address(game), type(uint256).max);
    }

    function _buy(uint256 amount) internal {
        vm.prank(ALICE);
        IPortalTradeV2(PORTAL).swapExactInput{value: amount, gas: 10_000_000}(
            IPortalTradeV2.ExactInputParams(address(0), address(token), amount, 0, "")
        );
    }

    function _dispatch() internal {
        uint256 pending = processor.marketQuoteBalance();
        uint256 beforeTotal = game.totalTaxesReceived();
        uint256 start = gasleft();
        processor.dispatch{gas: 1_000_000}();
        emit log_named_uint("Dispatch measured gas (warm fork call)", start - gasleft());
        assertEq(game.totalTaxesReceived(), beforeTotal + pending);
        assertEq(processor.marketQuoteBalance(), 0);
    }

    function _entry() internal {
        vm.prank(ALICE);
        game.enter();
    }

    function testForkLaunchEntryTimerAndManualSettlement() public {
        _entry();
        uint256 end = game.deadline();
        assertEq(end, block.timestamp + 21600);
        vm.warp(block.timestamp + 1000);
        _entry();
        assertEq(game.deadline(), end + 120);
        assertEq(token.balanceOf(game.DEAD()), 40000 ether);
        uint256 prize = game.jackpot();
        uint256 before = ALICE.balance;
        vm.warp(game.deadline());
        game.settle();
        assertEq(game.winnerOf(1), ALICE);
        assertEq(game.prizeOf(1), prize);
        assertTrue(game.claimedOf(1));
        assertEq(ALICE.balance, before + prize);
        assertEq(game.roundId(), 2);
        assertEq(game.deadline(), 0);
    }

    function testForkExpiredTaxPaysWinnerAndFundsNextRound() public {
        _entry();
        uint256 prize = game.jackpot();
        vm.warp(game.deadline());
        uint256 before = ALICE.balance;
        _buy(0.1 ether);
        _dispatch();
        assertEq(game.roundId(), 2);
        assertEq(game.prizeOf(1), prize);
        assertTrue(game.claimedOf(1));
        assertEq(ALICE.balance, before - 0.1 ether + prize);
        assertGt(game.jackpot(), 0);
        assertEq(game.deadline(), 0);
        assertEq(game.outstandingPrizes(), 0);
        uint256 nextPrize = game.jackpot();
        _entry();
        assertEq(game.deadline(), block.timestamp + 21600);
        vm.warp(game.deadline());
        game.settle();
        assertEq(game.prizeOf(2), nextPrize);
    }

    function testForkRejectedWinnerOldPrizeSurvivesNextRoundAndClaim() public {
        _entry();
        uint256 prize = game.jackpot();
        vm.etch(ALICE, hex"60006000fd");
        vm.warp(game.deadline());
        _buy(0.1 ether);
        _dispatch();
        assertEq(game.roundId(), 2);
        assertFalse(game.claimedOf(1));
        assertEq(game.outstandingPrizes(), prize);
        uint256 nextPrize = game.jackpot();
        vm.etch(ALICE, hex"");
        _entry();
        vm.warp(game.deadline());
        game.settle();
        assertEq(game.prizeOf(2), nextPrize);
        assertEq(address(game).balance, prize);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        game.claim(1);
        assertEq(ALICE.balance, before + prize);
        assertEq(game.outstandingPrizes(), 0);
        vm.prank(ALICE);
        vm.expectRevert(FOMO6FlapVault.AlreadyClaimed.selector);
        game.claim(1);
    }

    function testForkGraduationSellAndDispatch() public {
        _graduationSell(false);
    }

    function testForkGraduatedSellReceiptSettlesAndFundsNextRound() public {
        _graduationSell(true);
    }

    function _graduationSell(bool expired) private {
        _entry();
        _buy(30 ether);
        emit log_named_uint("Token pool state after large buy", uint256(token.state()));
        emit log_named_address("DEX pool", token.mainPool());
        // States 2 and 3 are real migrated tax-enforced DEX states.
        assertGe(uint256(token.state()), 2, "Token did not graduate");
        assertLe(uint256(token.state()), 3, "Unexpected tax-free state");
        _dispatch();
        _entry(); // Direct burn entry must also work during the real anti-farmer window.
        assertEq(token.balanceOf(game.DEAD()), 40000 ether);
        uint256 beforeTaxes = game.totalTaxesReceived();
        uint256 oldPrize = game.jackpot();
        if (expired) vm.warp(game.deadline());
        uint256 quantity = token.balanceOf(ALICE) / 20;
        vm.startPrank(ALICE);
        token.approve(PORTAL, type(uint256).max);
        IPortalTradeV2(PORTAL).swapExactInput{gas: 10_000_000}(
            IPortalTradeV2.ExactInputParams(address(token), address(0), quantity, 0, "")
        );
        assertGt(token.balanceOf(address(token)), 0, "First sell did not accumulate token tax");
        // A later sell triggers liquidation of tax accumulated by the first sell.
        IPortalTradeV2(PORTAL).swapExactInput{gas: 10_000_000}(
            IPortalTradeV2.ExactInputParams(address(token), address(0), quantity, 0, "")
        );
        vm.stopPrank();
        _dispatch();
        assertGt(game.totalTaxesReceived(), beforeTaxes, "Sell taxes were not delivered");
        if (expired) {
            assertEq(game.roundId(), 2);
            assertEq(game.prizeOf(1), oldPrize);
            assertTrue(game.claimedOf(1));
            assertGt(game.jackpot(), 0);
            assertEq(game.deadline(), 0);
        } else {
            assertLe(game.deadline() - block.timestamp, 21600);
        }
    }
}
