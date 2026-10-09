// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFOMO6Token {
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Local prototype: one immutable round, token entries and native BNB tax revenue.
/// @dev Not yet a Flap factory/vault integration. Token must have 18 decimals and exact transfers.
contract FOMO6 {
    uint256 public constant ENTRY_AMOUNT = 20_000 ether;
    uint256 public constant INITIAL_DURATION = 6 hours;
    uint256 public constant EXTENSION = 10 seconds;
    address public constant DEAD = address(0xdead);
    IFOMO6Token public immutable token;
    address public immutable taxProcessor;
    address public immutable portal;
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
    uint256 private locked = 1;

    enum State {
        WAITING,
        ACTIVE,
        ENDED,
        SETTLED
    }
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

    constructor(address t, address processor, address p, address recipient) {
        if (
            t.code.length == 0 || processor == address(0) || p == address(0) || recipient == address(0)
                || recipient == address(this)
        ) revert InvalidConfiguration();
        token = IFOMO6Token(t);
        taxProcessor = processor;
        portal = p;
        postSettlementRecipient = recipient;
    }

    modifier nonReentrant() {
        if (locked != 1) revert ReentrantCall();
        locked = 2;
        _;
        locked = 1;
    }

    /// @dev Revenue never starts the clock. No external calls on receipt.
    receive() external payable nonReentrant {
        if (msg.sender != taxProcessor && msg.sender != portal) revert UnauthorizedTaxSource();
        totalTaxesReceived += msg.value;
        if (settled) postSettlementTaxes += msg.value;
        else jackpot += msg.value;
        emit TaxReceived(msg.sender, msg.value, settled);
    }

    /// @notice Approve exactly ENTRY_AMOUNT first. Successful entries transfer directly to DEAD.
    function enter() external nonReentrant {
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
    }

    function state() external view returns (State) {
        if (settled) return State.SETTLED;
        if (deadline == 0) return State.WAITING;
        return block.timestamp < deadline ? State.ACTIVE : State.ENDED;
    }

    function settle() external nonReentrant {
        if (settled) revert AlreadySettled();
        if (deadline == 0 || block.timestamp < deadline) revert NotEnded();
        settled = true;
        winner = lastPlayer;
        prizeAtSettlement = jackpot;
        emit Settled(winner, jackpot);
    }

    function claim(address payable recipient) external nonReentrant {
        if (!settled) revert NotSettled();
        if (msg.sender != winner) revert NotWinner();
        if (claimed) revert AlreadyClaimed();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        uint256 amount = jackpot;
        claimed = true;
        jackpot = 0;
        _pay(recipient, amount);
        emit Claimed(winner, recipient, amount);
    }

    /// @notice Anyone can forward post-settlement taxes, only to the fixed recipient.
    function withdrawPostSettlementTaxes() external nonReentrant {
        uint256 amount = postSettlementTaxes;
        postSettlementTaxes = 0;
        _pay(payable(postSettlementRecipient), amount);
        emit PostSettlementTaxesWithdrawn(postSettlementRecipient, amount);
    }

    function _pay(address payable recipient, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
