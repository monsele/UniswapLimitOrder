// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {BaseHook} from "periphery-next/BaseHook.sol";
import {ERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
//import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "forge-std/console.sol";

contract TakeProfitsHook is BaseHook, ERC1155 {
    constructor(IPoolManager _poolManager, string memory _uri) BaseHook(_poolManager) ERC1155(_uri) {}

    // Use the PoolIdLibrary for PoolKey to add the `.toId()` function on a PoolKey
    // which hashes the PoolKey struct into a bytes32 value
    //using PoolIdLibrary for PoolKey;
    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    mapping(PoolId poolId => int24 tickLower) public tickLowerLast;
    // Create a nested mapping to store the take-profit orders placed by users
    // The mapping is PoolId => tickLower => zeroForOne => amount
    // PoolId => (...) specifies the ID of the pool the order is for
    // tickLower => (...) specifies the tickLower value of the order i.e. sell when price is greater than or equal to this tick
    // zeroForOne => (...) specifies whether the order is swapping Token 0 for Token 1 (true), or vice versa (false)
    // amount specifies the amount of the token being sold
    mapping(PoolId poolId => mapping(int24 tick => mapping(bool zeroForOne => int256 amount))) public
        takeProfitPositions;

    // tokenIdExists is a mapping to store whether a given tokenId (i.e. a take-profit order) exists given a token id
    mapping(uint256 tokenId => bool exists) public tokenIdExists;
    // tokenIdClaimable is a mapping that stores how many swapped tokens are claimable for a given tokenId
    mapping(uint256 tokenId => uint256 claimable) public tokenIdClaimable;
    // tokenIdTotalSupply is a mapping that stores how many tokens need to be sold to execute the take-profit order
    mapping(uint256 tokenId => uint256 supply) public tokenIdTotalSupply;
    // tokenIdData is a mapping that stores the PoolKey, tickLower, and zeroForOne values for a given tokenId
    mapping(uint256 tokenId => TokenData) public tokenIdData;

    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        _setTickLowerLast(key.toId(), _getTickLower(tick, key.tickSpacing));
        return TakeProfitsHook.afterInitialize.selector;
    }

    //Core
    function placeOrder(PoolKey calldata key, int24 tick, uint256 amountIn, bool zeroForOne) external returns (int24) {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        takeProfitPositions[key.toId()][tickLower][zeroForOne] += int256(amountIn);

        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);
        // If token id doesn't already exist, add it to the mapping
        // Not every order creates a new token id, as it's possible for users to add more tokens to a pre-existing order
        if (!tokenIdExists[tokenId]) {
            tokenIdExists[tokenId] = true;
            tokenIdData[tokenId] = TokenData(key, tickLower, zeroForOne);
        }

        // Mint ERC-1155 tokens to the user
        _mint(msg.sender, tokenId, amountIn, "");
        tokenIdTotalSupply[tokenId] += amountIn;

        // Extract the address of the token the user wants to sell
        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);

        // Move the tokens to be sold from the user to this contract
        IERC20(tokenToBeSoldContract).transferFrom(msg.sender, address(this), amountIn);

        return tickLower;
    }

    function afterSwap(address addr, PoolKey calldata key, IPoolManager.SwapParams calldata params, BalanceDelta)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        if (addr == address(this)) {
            return TakeProfitsHook.afterSwap.selector;
        }

        bool attemptToFillMoreOrders = true;
        int24 currentTickLower;
        while (attemptToFillMoreOrders) {
            (attemptToFillMoreOrders, currentTickLower) = _tryFulfillingOrders(key, params);
            tickLowerLasts[key.toId()] = currentTickLower;
        }

        return TakeProfitsHook.afterSwap.selector;
    }

    function _tryFulfillingOrders(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        returns (bool, int24)
    {
        // Get the exact current tick and use it to calculate the currentTickLower
        (, int24 currentTick,,,,) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = _getTickLower(currentTick, key.tickSpacing);
        int24 lastTickLower = tickLowerLasts[key.toId()];

        bool swapZeroForOne = !params.zeroForOne;

        int256 swapAmountIn;

        // If tick has increased (i.e. price of Token 1 has increased)
        if (lastTickLower < currentTickLower) {
            // Loop through all ticks between the lastTickLower and currentTickLower
            // and execute all orders that are oneForZero
            for (int24 tick = lastTickLower; tick < currentTickLower;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);

                    // The fulfillment of the above order has changed the current tick
                    // Refetch it and return
                    (, currentTick,,,,) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(currentTick, key.tickSpacing);
                    return (true, currentTickLower);
                }
                tick += key.tickSpacing;
            }
        }
        // Else if tick has decreased (i.e. price of Token 0 has increased)
        else {
            // Loop through all ticks between the lastTickLower and currentTickLower
            // and execute all orders that are zeroForOne
            for (int24 tick = lastTickLower; currentTickLower < tick;) {
                swapAmountIn = takeProfitPositions[key.toId()][tick][swapZeroForOne];
                if (swapAmountIn > 0) {
                    fillOrder(key, tick, swapZeroForOne, swapAmountIn);

                    // The fulfillment of the above order has changed the current tick
                    // Refetch it and return
                    (, currentTick,,,,) = poolManager.getSlot0(key.toId());
                    currentTickLower = _getTickLower(currentTick, key.tickSpacing);
                    return (true, currentTickLower);
                }
                tick -= key.tickSpacing;
            }
        }

        return (false, currentTickLower);
    }

    function cancelOrder(PoolKey calldata key, int24 tick, bool zeroForOne) external {
        int24 tickLower = _getTickLower(tick, key.tickSpacing);
        uint256 tokenId = getTokenId(key, tickLower, zeroForOne);

        // Get the amount of tokens the user's ERC-1155 tokens represent
        uint256 amountIn = balanceOf(msg.sender, tokenId);
        require(amountIn > 0, "TakeProfitsHook: No orders to cancel");

        takeProfitPositions[key.toId()][tickLower][zeroForOne] -= int256(amountIn);
        tokenIdTotalSupply[tokenId] -= amountIn;
        _burn(msg.sender, tokenId, amountIn);

        // Extract the address of the token the user wanted to sell
        address tokenToBeSoldContract = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        // Move the tokens to be sold from this contract back to the user
        IERC20(tokenToBeSoldContract).transfer(msg.sender, amountIn);
    }

    function _handleSwap(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (BalanceDelta)
    {
        // delta is the BalanceDelta struct that stores the delta balance changes
        // i.e. Change in Token 0 balance and change in Token 1 balance
        BalanceDelta delta = poolManager.swap(key, params);

        // If this swap was a swap for Token 0 to Token 1
        if (params.zeroForOne) {
            // If we owe Uniswap Token 0, we need to send them the required amount
            if (delta.amount0() > 0) {
                IERC20(Currency.unwrap(key.currency0)).transfer(address(poolManager), uint128(delta.amount0()));
                poolManager.settle(key.currency0);
            }

            // If we are owed Token 1, we need to `take` it from the Pool Manager
            // NOTE: This will be a negative value, as it is a negative balance change from the pool's perspective
            if (delta.amount1() < 0) {
                // We flip the sign of the amount to make it positive when taking it from the pool manager
                poolManager.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        }
        // Else if this swap was a swap for Token 1 to Token 0
        else {
            // Same as above
            // If we owe Uniswap Token 1, we need to send them the required amount
            if (delta.amount1() > 0) {
                IERC20(Currency.unwrap(key.currency1)).transfer(address(poolManager), uint128(delta.amount1()));
                poolManager.settle(key.currency1);
            }

            // If we are owed Token 0, we take it from the Pool Manager
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, address(this), uint128(-delta.amount0()));
            }
        }

        return delta;
    }

    //ERC-1155 Helpers
    // ERC-1155 Helpers
    function getTokenId(PoolKey calldata key, int24 tickLower, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key.toId(), tickLower, zeroForOne)));
    }

    // Utility Helpers
    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function _getTickLower(int24 actualTick, int24 tickSpacing) private pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }
}
