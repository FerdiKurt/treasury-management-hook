// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// Simplified interface for testing
interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    
    function take(Currency currency, address to, uint256 amount) external;
}

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

// Mock Pool Manager
contract MockPoolManager is IPoolManager {
    Currency public lastTakeToken;
    address public lastTakeAccount;
    uint256 public lastTakeAmount;
    
    function take(Currency currency, address to, uint256 amount) external override {
        lastTakeToken = currency;
        lastTakeAccount = to;
        lastTakeAmount = amount;
    }
}

// Simplified version of TreasuryManagementHook for testing
contract TreasuryManagement {
    IPoolManager public immutable poolManager;
    address public treasury;
    uint24 public treasuryFeeRate;
    
    // Mapping to track managed pools
    mapping(bytes32 => bool) public isPoolManaged;

    event TreasuryFeeCollected(bytes32 poolId, address token, uint256 amount);
    event TreasuryAddressChanged(address oldTreasury, address newTreasury);
    event TreasuryFeeRateChanged(uint24 oldRate, uint24 newRate);

    constructor(IPoolManager _poolManager, address _treasury, uint24 _treasuryFeeRate) {
        require(_treasury != address(0), "Invalid treasury address");
        require(_treasuryFeeRate <= 1000, "Fee rate too high"); // Max 10%
        
        poolManager = _poolManager;
        treasury = _treasury;
        treasuryFeeRate = _treasuryFeeRate;
    }

    function setTreasury(address _newTreasury) external {
        require(msg.sender == treasury, "Only treasury can update");
        require(_newTreasury != address(0), "Invalid treasury address");
        
        address oldTreasury = treasury;
        treasury = _newTreasury;
        
        emit TreasuryAddressChanged(oldTreasury, _newTreasury);
    }

    function setTreasuryFeeRate(uint24 _newFeeRate) external {
        require(msg.sender == treasury, "Only treasury can update");
        require(_newFeeRate <= 1000, "Fee rate too high"); // Max 10%
        
        uint24 oldRate = treasuryFeeRate;
        treasuryFeeRate = _newFeeRate;
        
        emit TreasuryFeeRateChanged(oldRate, _newFeeRate);
    }
    
    // For testing: manually add a pool to the managed pools
    function addManagedPool(bytes32 poolId) external {
        isPoolManaged[poolId] = true;
    }
    
    // Simulate the beforeSwap hook logic
    function calculateFee(bytes32 poolId) external view returns (uint24) {
        if (isPoolManaged[poolId]) {
            return treasuryFeeRate;
        }
        return 0;
    }
    
    // Simulate the afterSwap hook logic for token0 -> token1 swap
    function collectFeeToken0(bytes32 poolId, int128 amount0) external returns (int128) {
        if (!isPoolManaged[poolId] || amount0 <= 0) {
            return 0;
        }
        
        int128 feeAmount = (amount0 * int128(int24(treasuryFeeRate))) / 10000;
        
        if (feeAmount > 0) {
            emit TreasuryFeeCollected(poolId, address(0), uint256(uint128(feeAmount)));
        }
        
        return feeAmount;
    }
    
    // Simulate the afterSwap hook logic for token1 -> token0 swap
    function collectFeeToken1(bytes32 poolId, int128 amount1) external returns (int128) {
        if (!isPoolManaged[poolId] || amount1 <= 0) {
            return 0;
        }
        
        int128 feeAmount = (amount1 * int128(int24(treasuryFeeRate))) / 10000;
        
        if (feeAmount > 0) {
            emit TreasuryFeeCollected(poolId, address(0), uint256(uint128(feeAmount)));
        }
        
        return feeAmount;
    }
    
    function withdrawFees(Currency currency, uint256 amount) external {
        require(msg.sender == treasury, "Only treasury can withdraw");
        poolManager.take(currency, treasury, amount);
    }
}

contract TreasuryManagementTest is Test {
    MockPoolManager public poolManager;
    TreasuryManagement public treasuryManagement;
    MockToken public token0;
    MockToken public token1;
    
    // Test accounts
    address public treasury = address(0x1);
    address public user = address(0x2);
    address public newTreasury = address(0x3);
    
    // Test parameters
    uint24 public treasuryFeeRate = 50; // 0.5%
    uint24 public newFeeRate = 100; // 1%
    
    // Test pool ID
    bytes32 public poolId = keccak256("test-pool");
    
    function setUp() public {
        // Deploy mock contracts
        poolManager = new MockPoolManager();
        token0 = new MockToken("Token0", "TKN0");
        token1 = new MockToken("Token1", "TKN1");
        
        // Deploy treasury management
        treasuryManagement = new TreasuryManagement(
            poolManager, 
            treasury, 
            treasuryFeeRate
        );
        
        // Make sure treasury has some ETH for testing
        vm.deal(treasury, 10 ether);
        
        // Register the test pool as managed
        treasuryManagement.addManagedPool(poolId);
    }
    
    function test_Constructor() public view {
        assertEq(address(treasuryManagement.poolManager()), address(poolManager), "Pool manager address incorrect");
        assertEq(treasuryManagement.treasury(), treasury, "Treasury address incorrect");
        assertEq(treasuryManagement.treasuryFeeRate(), treasuryFeeRate, "Treasury fee rate incorrect");
    }
    
    function test_RevertIf_InvalidTreasuryInConstructor() public {
        vm.expectRevert("Invalid treasury address");
        new TreasuryManagement(poolManager, address(0), treasuryFeeRate);
    }
    
    function test_RevertIf_FeeRateTooHighInConstructor() public {
        vm.expectRevert("Fee rate too high");
        new TreasuryManagement(poolManager, treasury, 1001); // Over 10%
    }
    
    function test_SetTreasury() public {
        // Call with treasury address
        vm.prank(treasury);
        treasuryManagement.setTreasury(newTreasury);
        
        // Verify treasury was updated
        assertEq(treasuryManagement.treasury(), newTreasury, "Treasury address not updated");
    }
    
    function test_RevertIf_SetTreasuryNotTreasury() public {
        // Call with non-treasury address
        vm.prank(user);
        vm.expectRevert("Only treasury can update");
        treasuryManagement.setTreasury(newTreasury);
    }
    
    function test_RevertIf_SetTreasuryZeroAddress() public {
        // Call with zero address
        vm.prank(treasury);
        vm.expectRevert("Invalid treasury address");
        treasuryManagement.setTreasury(address(0));
    }
    
    function test_SetTreasuryFeeRate() public {
        // Call with treasury address
        vm.prank(treasury);
        treasuryManagement.setTreasuryFeeRate(newFeeRate);
        
        // Verify fee rate was updated
        assertEq(treasuryManagement.treasuryFeeRate(), newFeeRate, "Treasury fee rate not updated");
    }
    
    function test_RevertIf_SetTreasuryFeeRateNotTreasury() public {
        // Call with non-treasury address
        vm.prank(user);
        vm.expectRevert("Only treasury can update");
        treasuryManagement.setTreasuryFeeRate(newFeeRate);
    }
    
    function test_RevertIf_SetTreasuryFeeRateTooHigh() public {
        // Call with too high fee rate
        vm.prank(treasury);
        vm.expectRevert("Fee rate too high");
        treasuryManagement.setTreasuryFeeRate(1001); // Over 10%
    }
    
    function test_CalculateFee_ManagedPool() public view {
        uint24 fee = treasuryManagement.calculateFee(poolId);
        assertEq(fee, treasuryFeeRate, "Fee rate not applied for managed pool");
    }
    
    function test_CalculateFee_UnmanagedPool() public view {
        bytes32 unmanagedPoolId = keccak256("unmanaged-pool");
        uint24 fee = treasuryManagement.calculateFee(unmanagedPoolId);
        assertEq(fee, 0, "Fee rate should be zero for unmanaged pool");
    }
    
