// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {ITaxProcessor} from "./flap/ITaxProcessor.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./flap/IVaultSchemasV1.sol";

interface IFOMO6FlapToken {
    function decimals() external view returns (uint8);
    function taxProcessor() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Immutable Flap vault integration candidate; not yet cleared for public launch.
/// @dev Independent rounds and reserved unpaid prizes; verified native tax receipts fund the next/current round.
contract FOMO6FlapVault is VaultBaseV2 {
    using SafeERC20 for IERC20;
    uint256 public constant ENTRY_AMOUNT = 20_000 ether;
    uint256 public constant INITIAL_DURATION = 6 hours;
    uint256 public constant EXTENSION = 120 seconds;
    address public constant DEAD = address(0xdead);
    IFOMO6FlapToken public immutable token;
    address public taxProcessor;
    mapping(address => uint256) public pendingBySource;
    address public lastPlayer;
    uint256 public roundId = 1;
    uint256 public deadline;
    uint256 public entries;
    uint256 public jackpot;
    uint256 public totalTaxesReceived;
    uint256 public outstandingPrizes;
    mapping(uint256 => address) public winnerOf;
    mapping(uint256 => uint256) public prizeOf;
    mapping(uint256 => bool) public claimedOf;
    bool public emergencyStopped;
    uint256 public totalEmergencyWithdrawn;
    uint256 public emergencyReceipts;
    uint256 private locked = 1;

    enum State {
        WAITING,
        ACTIVE,
        ENDED,
        EMERGENCY_STOPPED
    }
    error EmergencyStopped();
    error InvalidConfiguration();
    error UnauthorizedTaxSource();
    error ReentrantCall();
    error GameEnded();
    error TokenTransferFailed();
    error WrongTokenAmount();
    error NotEnded();
    error NotWinner();
    error NotSettled();
    error AlreadyClaimed();
    error TransferFailed();

    event Entry(uint256 indexed round, address indexed player, uint256 deadline, uint256 entries);
    event TaxReceived(address indexed source, uint256 indexed round, uint256 amount);
    event Settled(uint256 indexed round, address indexed winner, uint256 prize);
    event Claimed(uint256 indexed round, address indexed winner, uint256 amount);
    event AutomaticPaymentFailed(uint256 indexed round, address indexed winner, uint256 amount);
    event TaxProcessorBound(address indexed processor, uint256 pendingCredited);
    event PendingReceipt(address indexed source, uint256 amount);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    event EmergencyReceipt(address indexed source, uint256 amount);
    error InvalidTaxProcessor();

    constructor(address predictedToken) {
        if (predictedToken == address(0)) revert InvalidConfiguration();
        token = IFOMO6FlapToken(predictedToken);
    }

    /// @notice Anyone may verify the immutable token's processor; no address argument or setter.
    function bindTaxProcessor() external nonReentrant {
        _bind();
    }

    function _bind() private {
        if (emergencyStopped) revert EmergencyStopped();
        if (taxProcessor != address(0)) return;
        if (address(token).code.length == 0 || token.decimals() != 18) revert InvalidTaxProcessor();
        address candidate = token.taxProcessor();
        if (candidate.code.length == 0) revert InvalidTaxProcessor();
        ITaxProcessor p = ITaxProcessor(candidate);
        if (p.taxToken() != address(token) || p.marketAddress() != address(this) || !p.feeConfig().isWeth) {
            revert InvalidTaxProcessor();
        }
        if (p.getQuoteToken() != p.weth()) revert InvalidTaxProcessor();
        taxProcessor = candidate;
        uint256 pending = pendingBySource[candidate];
        delete pendingBySource[candidate];
        jackpot += pending;
        totalTaxesReceived += pending;
        emit TaxProcessorBound(candidate, pending);
    }

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @dev An expired receipt settles the old round before funding the waiting next round.
    receive() external payable nonReentrant {
        if (emergencyStopped) {
            emergencyReceipts += msg.value;
            emit EmergencyReceipt(msg.sender, msg.value);
            return;
        }
        if (taxProcessor == address(0)) {
            if (msg.value != 0) {
                pendingBySource[msg.sender] += msg.value;
                emit PendingReceipt(msg.sender, msg.value);
            }
            return;
        }
        if (msg.sender != taxProcessor) revert UnauthorizedTaxSource();
        if (deadline != 0 && block.timestamp >= deadline) _settle();
        totalTaxesReceived += msg.value;
        jackpot += msg.value;
        emit TaxReceived(msg.sender, roundId, msg.value);
    }

    /// @notice Approve at least ENTRY_AMOUNT first. Successful entries transfer directly to DEAD.
    function enter() external nonReentrant {
        _bind();
        if (deadline != 0 && block.timestamp >= deadline) revert GameEnded();
        uint256 beforeDead = token.balanceOf(DEAD);
        uint256 beforePlayer = token.balanceOf(msg.sender);
        (bool ok, bytes memory result) =
            address(token).call(abi.encodeCall(token.transferFrom, (msg.sender, DEAD, ENTRY_AMOUNT)));
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenTransferFailed();
        }
        // Reject taxed, partial, rebasing or otherwise inexact entry transfers atomically.
        if (
            token.balanceOf(DEAD) != beforeDead + ENTRY_AMOUNT || beforePlayer < ENTRY_AMOUNT
                || token.balanceOf(msg.sender) != beforePlayer - ENTRY_AMOUNT
        ) {
            revert WrongTokenAmount();
        }
        uint256 cap = block.timestamp + INITIAL_DURATION;
        uint256 extended = deadline + EXTENSION;
        deadline = deadline == 0 || extended > cap ? cap : extended;
        lastPlayer = msg.sender;
        entries++;
        emit Entry(roundId, msg.sender, deadline, entries);
    }

    function state() external view returns (State) {
        if (emergencyStopped) return State.EMERGENCY_STOPPED;
        if (deadline == 0) return State.WAITING;
        return block.timestamp < deadline ? State.ACTIVE : State.ENDED;
    }

    /// @notice Anyone may settle an expired active round and attempt winner-only payment.
    function settle() external nonReentrant {
        if (emergencyStopped) revert EmergencyStopped();
        if (deadline == 0 || block.timestamp < deadline) revert NotEnded();
        _settle();
    }

    function _settle() private {
        uint256 id = roundId;
        address winner = lastPlayer;
        uint256 amount = jackpot;
        winnerOf[id] = winner;
        prizeOf[id] = amount;
        outstandingPrizes += amount;
        roundId = id + 1;
        deadline = 0;
        lastPlayer = address(0);
        entries = 0;
        jackpot = 0;
        emit Settled(id, winner, amount);
        claimedOf[id] = true;
        outstandingPrizes -= amount;
        bool ok = true;
        if (amount != 0) {
            assembly ("memory-safe") { ok := call(30000, winner, amount, 0, 0, 0, 0) }
        }
        if (ok) {
            emit Claimed(id, winner, amount);
        } else {
            claimedOf[id] = false;
            outstandingPrizes += amount;
            emit AutomaticPaymentFailed(id, winner, amount);
        }
    }

    /// @notice Only that round's winner may retry payment, exclusively to itself.
    function claim(uint256 id) external nonReentrant {
        if (emergencyStopped) revert EmergencyStopped();
        if (id == 0 || id >= roundId) revert NotSettled();
        address winner = winnerOf[id];
        if (msg.sender != winner) revert NotWinner();
        if (claimedOf[id]) revert AlreadyClaimed();
        uint256 amount = prizeOf[id];
        claimedOf[id] = true;
        outstandingPrizes -= amount;
        _pay(payable(winner), amount);
        emit Claimed(id, winner, amount);
    }

    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), "Only Guardian");
        _;
    }

    /// @notice Guardian may remove ALL native funds, including an unclaimed prize.
    /// @dev Irreversible round stop. Subsequent receipts can still be recovered by Guardian.
    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0) && to != address(this), "Invalid emergency destination");
        emergencyStopped = true;
        uint256 amount = address(this).balance;
        totalEmergencyWithdrawn += amount;
        _pay(payable(to), amount);
        emit EmergencyWithdrawNative(to, amount);
    }

    /// @notice Guardian-only recovery of accidentally held ERC20 tokens; no allowance access.
    function emergencyWithdrawToken(address heldToken, address to) external onlyGuardian nonReentrant {
        require(heldToken != address(0) && to != address(0) && to != address(this), "Invalid emergency destination");
        IERC20 held = IERC20(heldToken);
        uint256 amount = held.balanceOf(address(this));
        if (amount != 0) held.safeTransfer(to, amount);
        emit EmergencyWithdrawToken(heldToken, to, amount);
    }

    function taxToken() external view returns (address) {
        return address(token);
    }

    function description() public view override returns (string memory) {
        return emergencyStopped
            ? "FOMO6: Guardian stopped all rounds and claims."
            : "FOMO6: repeating six-hour rounds; each entry adds 120 seconds.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FOMO6";
        schema.description =
            "20,000 tokens sent to burn address per entry. Six-hour remaining cap, +120 seconds. New rounds start with first entry; taxes between rounds fund the next jackpot. Unpaid previous prizes are reserved. Guardian may recover all funds and stop all claims.";
        string[16] memory names = [
            "ENTRY_AMOUNT",
            "roundId",
            "deadline",
            "jackpot",
            "lastPlayer",
            "outstandingPrizes",
            "winnerOf",
            "prizeOf",
            "claimedOf",
            "emergencyStopped",
            "bindTaxProcessor",
            "enter",
            "settle",
            "claim",
            "emergencyWithdrawNative",
            "emergencyWithdrawToken"
        ];
        schema.methods = new VaultMethodSchema[](16);
        for (uint256 i; i < 16; ++i) {
            VaultMethodSchema memory m;
            m.name = names[i];
            m.description = names[i];
            m.isWriteMethod = i >= 10;
            m.inputs = new FieldDescriptor[](i == 15 ? 2 : (i == 6 || i == 7 || i == 8 || i == 13 || i == 14 ? 1 : 0));
            if (m.inputs.length != 0) m.inputs[0] = FieldDescriptor("round", "uint256", "Settled round number", 0);
            if (i == 14) m.inputs[0] = FieldDescriptor("to", "address", "Guardian recovery destination", 0);
            if (i == 15) {
                m.inputs[0] = FieldDescriptor("heldToken", "address", "Token to recover", 0);
                m.inputs[1] = FieldDescriptor("to", "address", "Guardian recovery destination", 0);
            }
            m.outputs = new FieldDescriptor[](i < 10 ? 1 : 0);
            if (m.outputs.length != 0) {
                m.outputs[0] = FieldDescriptor(
                    "value",
                    i == 4 || i == 6 ? "address" : (i == 8 || i == 9 ? "bool" : (i == 2 ? "time" : "uint256")),
                    names[i],
                    i == 0 || i == 3 || i == 5 || i == 7 ? 18 : 0
                );
            }
            m.approvals = new ApproveAction[](0);
            schema.methods[i] = m;
        }
    }

    function _pay(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
