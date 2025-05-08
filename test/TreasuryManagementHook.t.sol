// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";



// Simple mock token
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    
    mapping(address => uint256) private _balances;
    
    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }
    
    function mint(address to, uint256 amount) external {
        _balances[to] += amount;
    }
    
    function burn(address from, uint256 amount) external {
        require(_balances[from] >= amount, "Insufficient balance");
        _balances[from] -= amount;
    }
    
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }
}

