// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {FOMO6} from "../../src/FOMO6.sol";

contract FOMO6MockToken {
    string public constant name = "FOMO6 Test Token";
    string public constant symbol = "tFOMO6";
    uint8 public constant decimals = 18;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public taxBps;
    uint256 public mode;
    FOMO6 public attackGame;
    uint256 public blocked;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address to, uint256 amount) external returns (bool) {
        allowance[msg.sender][to] = amount;
        emit Approval(msg.sender, to, amount);
        return true;
    }

    function configure(uint256 tax, uint256 m, FOMO6 game) external {
        taxBps = tax;
        mode = m;
        attackGame = game;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * taxBps / 10_000;
        emit Transfer(from, to, amount - amount * taxBps / 10_000);
        if (address(attackGame) != address(0)) {
            (bool a,) = address(attackGame).call(abi.encodeCall(attackGame.enter, ()));
            (bool b,) = address(attackGame).call(abi.encodeCall(attackGame.settle, ()));
            require(!a && !b);
            blocked += 2;
        }
        if (mode == 1) return false;
        if (mode == 2) {
            assembly { return(0, 0) }
        }
        return true;
    }
}

contract FOMO6Receiver {
    FOMO6 public game;
    bool public reject;
    bool public attack;
    uint256 public blocked;

    function configure(FOMO6 g, bool r, bool a) external {
        game = g;
        reject = r;
        attack = a;
    }

    function enter(FOMO6MockToken t) external {
        t.approve(address(game), game.ENTRY_AMOUNT());
        game.enter();
    }

    function claim(address payable to) external {
        game.claim(to);
    }

    receive() external payable {
        require(!reject);
        if (attack) {
            (bool a,) = address(game).call(abi.encodeCall(game.claim, (payable(address(this)))));
            (bool b,) = address(game).call(abi.encodeCall(game.withdrawPostSettlementTaxes, ()));
            (bool c,) = address(game).call(abi.encodeCall(game.settle, ()));
            (bool d,) = address(game).call(abi.encodeCall(game.enter, ()));
            require(!a && !b && !c && !d);
            blocked += 4;
        }
    }
}

contract FOMO6ForceBNB {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}
