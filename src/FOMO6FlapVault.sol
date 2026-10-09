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
/// @dev One round. Receipts perform accounting only; binding uses verified token/processor links.
contract FOMO6FlapVault is VaultBaseV2 {
    using SafeERC20 for IERC20;
    uint256 public constant ENTRY_AMOUNT = 20_000 ether;
    uint256 public constant INITIAL_DURATION = 6 hours;
    uint256 public constant EXTENSION = 30 seconds;
    address public constant DEAD = address(0xdead);
    IFOMO6FlapToken public immutable token;
    address public taxProcessor;
    mapping(address => uint256) public pendingBySource;
    address public immutable postSettlementRecipient;
    address public lastPlayer;
    address public winner;
    uint256 public deadline;
    uint256 public entries;
    uint256 public jackpot;
    uint256 public prizeAtSettlement;
    uint256 public postSettlementTaxes;
    uint256 public totalTaxesReceived;
    bool public settled;
    bool public claimed;
    bool public emergencyStopped;
    uint256 public jackpotAtEmergency;
    uint256 public postTaxesAtEmergency;
    uint256 public emergencyReceipts;
    uint256 public totalEmergencyWithdrawn;
    uint256 private locked = 1;
    bool private collectingTaxes;
    uint256 public constant AUTO_COLLECTION_GAS = 300_000;
    event AutoTaxCollection(bool succeeded);

    enum State {
        WAITING,
        ACTIVE,
        ENDED,
        SETTLED,
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
    error AlreadySettled();
    error NotWinner();
    error NotSettled();
    error AlreadyClaimed();
    error InvalidRecipient();
    error TransferFailed();

    event Entry(address indexed player, uint256 deadline, uint256 entries);
    event TaxReceived(address indexed source, uint256 amount, bool afterSettlement);
    event Settled(address indexed winner, uint256 prize);
    event Claimed(address indexed winner, address indexed recipient, uint256 amount);
    event PostSettlementTaxesWithdrawn(address indexed recipient, uint256 amount);

    event TaxProcessorBound(address indexed processor, uint256 pendingCredited);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    event EmergencyReceipt(address indexed source, uint256 amount);
    event EmergencyStop(uint256 jackpot, uint256 postSettlementTaxes);
    event PendingReceipt(address indexed source, uint256 amount);
    error InvalidTaxProcessor();

    constructor(address predictedToken, address recipient) {
        if (predictedToken == address(0) || recipient == address(0) || recipient == address(this)) {
            revert InvalidConfiguration();
        }
        token = IFOMO6FlapToken(predictedToken);
        postSettlementRecipient = recipient;
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
        if (locked != 1 || collectingTaxes) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @dev Revenue never starts the clock. Expired receipts settle and attempt bounded payments.
    receive() external payable {
        if (locked != 1) revert ReentrantCall();
        // Accept the verified dispatch callback, then lock before external payments.
        if (emergencyStopped) {
            emergencyReceipts += msg.value;
            emit EmergencyReceipt(msg.sender, msg.value);
            return;
        }
        // Early dispatch can precede token initialization. Do not call any external contract here.
        if (taxProcessor == address(0)) {
            if (msg.value != 0) {
                pendingBySource[msg.sender] += msg.value;
                emit PendingReceipt(msg.sender, msg.value);
            }
            return;
        }
        if (msg.sender != taxProcessor) revert UnauthorizedTaxSource();
        locked = 2;
        // Expired receipts belong to the fixed recipient, not the frozen prize.
        if (!settled && deadline != 0 && block.timestamp >= deadline) _settle();
        totalTaxesReceived += msg.value;
        if (settled) postSettlementTaxes += msg.value;
        else jackpot += msg.value;
        emit TaxReceived(msg.sender, msg.value, settled);
        if (settled) {
            _tryWinnerPayment();
            _tryPostTaxPayment();
        }
        locked = 1;
    }

    /// @notice Anyone may request distribution of accumulated, processed taxes.
    /// @dev Block game actions during dispatch, but permit its native receipt callback.
    function collectTaxes() external nonReentrant {
        _bind();
        collectingTaxes = true;
        locked = 1;
        ITaxProcessor(taxProcessor).dispatch();
        locked = 2;
        collectingTaxes = false;
    }

    /// @notice Approve at least ENTRY_AMOUNT first. Successful entries transfer directly to DEAD.
    function enter() external nonReentrant {
        _bind();
        if (settled || (deadline != 0 && block.timestamp >= deadline)) revert GameEnded();
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
        emit Entry(msg.sender, deadline, entries);
        // Bounded best effort: never make entry depend on processor success.
        if (gasleft() > AUTO_COLLECTION_GAS + 60_000) {
            collectingTaxes = true;
            locked = 1;
            address processor = taxProcessor;
            bytes4 selector = ITaxProcessor.dispatch.selector;
            bool collected;
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, selector)
                collected := call(300000, processor, 0, ptr, 4, 0, 0)
            }
            locked = 2;
            collectingTaxes = false;
            emit AutoTaxCollection(collected);
        } else {
            emit AutoTaxCollection(false);
        }
    }

    function state() external view returns (State) {
        if (emergencyStopped) return State.EMERGENCY_STOPPED;
        if (settled) return State.SETTLED;
        if (deadline == 0) return State.WAITING;
        return block.timestamp < deadline ? State.ACTIVE : State.ENDED;
    }

    function settle() external nonReentrant {
        if (emergencyStopped) revert EmergencyStopped();
        if (settled) revert AlreadySettled();
        if (deadline == 0 || block.timestamp < deadline) revert NotEnded();
        _settle();
    }

    function _settle() private {
        settled = true;
        winner = lastPlayer;
        prizeAtSettlement = jackpot;
        emit Settled(winner, jackpot);
    }

    event AutomaticPaymentFailed(address indexed recipient, uint256 amount);

    function _boundedPay(address recipient, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") { ok := call(30000, recipient, amount, 0, 0, 0, 0) }
    }

    function _tryWinnerPayment() private {
        if (claimed) return;
        uint256 amount = jackpot;
        claimed = true;
        jackpot = 0;
        if (amount == 0 || _boundedPay(winner, amount)) {
            emit Claimed(winner, winner, amount);
        } else {
            claimed = false;
            jackpot = amount;
            emit AutomaticPaymentFailed(winner, amount);
        }
    }

    function _tryPostTaxPayment() private {
        uint256 amount = postSettlementTaxes;
        if (amount == 0) return;
        postSettlementTaxes = 0;
        if (_boundedPay(postSettlementRecipient, amount)) {
            emit PostSettlementTaxesWithdrawn(postSettlementRecipient, amount);
        } else {
            postSettlementTaxes = amount;
            emit AutomaticPaymentFailed(postSettlementRecipient, amount);
        }
    }

    function claim() external nonReentrant {
        if (emergencyStopped) revert EmergencyStopped();
        if (!settled) revert NotSettled();
        if (msg.sender != winner) revert NotWinner();
        if (claimed) revert AlreadyClaimed();
        uint256 amount = jackpot;
        claimed = true;
        jackpot = 0;
        _pay(payable(winner), amount);
        emit Claimed(winner, winner, amount);
    }

    /// @notice Anyone can forward post-settlement taxes, only to the fixed recipient.
    function withdrawPostSettlementTaxes() external nonReentrant {
        if (emergencyStopped) revert EmergencyStopped();
        uint256 amount = postSettlementTaxes;
        postSettlementTaxes = 0;
        _pay(payable(postSettlementRecipient), amount);
        emit PostSettlementTaxesWithdrawn(postSettlementRecipient, amount);
    }

    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), "Only Guardian");
        _;
    }

    /// @notice Guardian may remove ALL native funds, including an unclaimed prize.
    /// @dev Irreversible round stop. Subsequent receipts can still be recovered by Guardian.
    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0) && to != address(this), "Invalid emergency destination");
        if (!emergencyStopped) {
            emergencyStopped = true;
            jackpotAtEmergency = jackpot;
            postTaxesAtEmergency = postSettlementTaxes;
            emit EmergencyStop(jackpot, postSettlementTaxes);
            jackpot = 0;
            postSettlementTaxes = 0;
        }
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
        if (emergencyStopped) {
            return "FOMO6: permanently stopped by Guardian emergency withdrawal. Claims are disabled.";
        }
        if (settled) return "FOMO6: settled; the winner can claim the fixed prize.";
        if (deadline == 0) return "FOMO6: waiting for the first successful token entry.";
        return block.timestamp < deadline
            ? "FOMO6: active; last player before expiry wins."
            : "FOMO6: ended; anyone can settle.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "FOMO6";
        schema.description =
            "20,000 tokens burned per entry. First entry starts six hours; later entries add 30 seconds, capped at six hours remaining. Only verified BNB tax revenue funds the prize. Flap Guardian can emergency-withdraw all funds and permanently stop the round.";
        schema.methods = new VaultMethodSchema[](15);
        string[15] memory names = [
            "ENTRY_AMOUNT",
            "deadline",
            "jackpot",
            "lastPlayer",
            "winner",
            "postSettlementTaxes",
            "bindTaxProcessor",
            "enter",
            "settle",
            "claim",
            "withdrawPostSettlementTaxes",
            "emergencyStopped",
            "emergencyWithdrawNative",
            "emergencyWithdrawToken",
            "collectTaxes"
        ];
        for (uint256 i; i < 15; ++i) {
            VaultMethodSchema memory m;
            m.name = names[i];
            m.description = names[i];
            m.inputs = new FieldDescriptor[](i == 13 ? 2 : (i == 12 ? 1 : 0));
            m.outputs = new FieldDescriptor[](i < 6 || i == 11 ? 1 : 0);
            m.approvals = new ApproveAction[](0);
            m.isWriteMethod = i >= 6 && i != 11;
            if (i == 11) m.outputs[0] = FieldDescriptor("stopped", "bool", "Guardian emergency stop", 0);
            if (i == 12) m.inputs[0] = FieldDescriptor("to", "address", "Guardian-selected recovery destination", 0);
            if (i == 13) {
                m.inputs[0] = FieldDescriptor("heldToken", "address", "Token to recover", 0);
                m.inputs[1] = FieldDescriptor("to", "address", "Recovery destination", 0);
            }
            if (i < 6) {
                m.outputs[0] = FieldDescriptor(
                    "value",
                    i == 1 ? "time" : (i == 3 || i == 4 ? "address" : "uint256"),
                    names[i],
                    i == 0 || i == 2 || i == 5 ? 18 : 0
                );
            }
            schema.methods[i] = m;
        }
        // Fixed-price enter() has no amount input. Read ENTRY_AMOUNT and approve via the DApp.
    }

    function _pay(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
