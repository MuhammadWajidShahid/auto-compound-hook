// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {CurrencySettler} from "v4-core-test/utils/CurrencySettler.sol";

import {CurrencyDelta} from "v4-core/libraries/CurrencyDelta.sol";

import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {SafeCast} from "v4-core/libraries/SafeCast.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

contract AutoCompound is BaseHook {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using CurrencyDelta for Currency;

    using SafeCast for uint256;
    using SafeCast for uint128;

    uint128 constant Q64 = 2 ** 64;
    uint128 constant Q96 = 2 ** 96;

    mapping(PoolId id => bool) public supportedPool;

    mapping(bytes32 => int256) public totalShares;

    mapping(bytes32 => int256) public userShares;

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
    }

    struct HookData {
        int24 tickLower;
        int24 tickUpper;
    }

    struct AutoCompoundState {
        uint160 sqrtPriceX96;
        uint256 autoLiqudity;
        uint256 usefee0;
        uint256 usefee1;
        BalanceDelta earnedFeeDelta;
        BalanceDelta liquidityDelta;
        BalanceDelta userDelta;
        BalanceDelta swapDelta;
    }

    struct SwapState {
        uint256 delta0;
        uint256 delta1;
        uint256 amountRatioX96;
        bool sell0;
        uint256 positionAmount0;
        uint256 positionAmount1;
        BalanceDelta swapDelta;
    }

    struct SwapParams {
        PoolKey key;
        uint256 amount0;
        uint256 amount1;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
    }

    struct SwapAutoCompoundState {
        uint160 sqrtPriceX96;
        BalanceDelta earnedFeeDelta;
        BalanceDelta liquidityDelta;
        BalanceDelta swapDelta;
    }

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
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
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        returns (bytes4)
    {
        supportedPool[key.toId()] = true;
        return this.afterInitialize.selector;
    }

    /**
     * @dev calculates the liquidity of a user depending on the shares amount user have.
     */
    function getUserLiquidity(address user, PoolKey calldata key, int24 tickLower, int24 tickUpper, bytes32 salt)
        public
        view
        returns (int256 liquidity)
    {
        uint128 totalLiquidity = poolManager.getPosition(key.toId(), address(this), tickLower, tickUpper, 0).liquidity;
        bytes32 id = getUserId(user, tickLower, tickUpper, salt);

        int256 total = totalShares[getPoolId(key.toId(), tickLower, tickUpper)];

        if (totalLiquidity > 0 && total > 0) {
            liquidity = (
                (userShares[id] / totalShares[getPoolId(key.toId(), tickLower, tickUpper)]) * totalLiquidity.toInt256()
            );
        }
    }

    function getUserId(address user, int24 tickLower, int24 tickUpper, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(user, tickLower, tickUpper, salt));
    }

    function getPoolId(PoolId id, int24 tickLower, int24 tickUpper) public pure returns (bytes32) {
        return keccak256(abi.encode(id, tickLower, tickUpper));
    }

    function modifyLiquidity(PoolKey calldata key, IPoolManager.ModifyLiquidityParams memory params)
        public
        payable
        returns (BalanceDelta delta)
    {
        require(supportedPool[key.toId()], "Pool not supported");

        int256 userLiq = getUserLiquidity(msg.sender, key, params.tickLower, params.tickUpper, params.salt);

        (delta) = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, ""))), (BalanceDelta));

        bytes32 id = getUserId(msg.sender, params.tickLower, params.tickUpper, params.salt);

        require(userLiq + params.liquidityDelta >= 0, "extra withdraw");

        userShares[id] += params.liquidityDelta;

        totalShares[getPoolId(key.toId(), params.tickLower, params.tickUpper)] += params.liquidityDelta;

        uint256 ethBalance = address(this).balance;

        if (ethBalance > 0) {
            CurrencyLibrary.NATIVE.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external override poolManagerOnly returns (bytes memory) {
        require(msg.sender == address(poolManager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        AutoCompoundState memory state;

        uint128 liquidity = poolManager.getPosition(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        ).liquidity;

        // Todo: reading fee deltas will reduce the additional modify call here.
        if (liquidity > 0) {
            (, state.earnedFeeDelta) = poolManager.modifyLiquidity(
                data.key,
                IPoolManager.ModifyLiquidityParams(data.params.tickLower, data.params.tickUpper, 0, data.params.salt),
                ""
            );
        }

        (state.sqrtPriceX96,,,) = poolManager.getSlot0(data.key.toId());

        uint256 amount0 = uint256(int256(state.earnedFeeDelta.amount0()));
        uint256 amount1 = uint256(int256(state.earnedFeeDelta.amount1()));

        state.swapDelta = _autoswap(
            SwapParams(data.key, amount0, amount1, state.sqrtPriceX96, data.params.tickLower, data.params.tickUpper)
        );

        state.earnedFeeDelta = state.earnedFeeDelta - state.swapDelta;

        state.autoLiqudity = LiquidityAmounts.getLiquidityForAmounts(
            state.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(data.params.tickLower),
            TickMath.getSqrtPriceAtTick(data.params.tickUpper),
            uint256(int256(state.earnedFeeDelta.amount0())),
            uint256(int256(state.earnedFeeDelta.amount1()))
        );

        (state.usefee0, state.usefee1) = LiquidityAmounts.getAmountsForLiquidity(
            state.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(data.params.tickLower),
            TickMath.getSqrtPriceAtTick(data.params.tickUpper),
            uint128(state.autoLiqudity)
        );

        (state.liquidityDelta,) = poolManager.modifyLiquidity(
            data.key,
            IPoolManager.ModifyLiquidityParams(
                data.params.tickLower,
                data.params.tickUpper,
                data.params.liquidityDelta + int256(state.autoLiqudity),
                data.params.salt
            ),
            data.hookData
        );

        uint256 feeDelta0 = uint256(int256(state.earnedFeeDelta.amount0())) - state.usefee0;
        uint256 feeDelta1 = uint256(int256(state.earnedFeeDelta.amount1())) - state.usefee1;

        if (feeDelta0 > 0) data.key.currency0.take(poolManager, address(this), feeDelta0, true);
        if (feeDelta1 > 0) data.key.currency1.take(poolManager, address(this), feeDelta1, true);

        state.userDelta = state.liquidityDelta + toBalanceDelta(state.usefee0.toInt128(), state.usefee1.toInt128());

        int256 delta0 = state.userDelta.amount0();
        int256 delta1 = state.userDelta.amount1();

        if (delta0 < 0) data.key.currency0.settle(poolManager, data.sender, uint256(-delta0), false);
        if (delta1 < 0) data.key.currency1.settle(poolManager, data.sender, uint256(-delta1), false);

        if (delta0 > 0) data.key.currency0.take(poolManager, data.sender, uint256(delta0), false);
        if (delta1 > 0) data.key.currency1.take(poolManager, data.sender, uint256(delta1), false);

        return abi.encode(state.userDelta);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata hookdata
    ) external override poolManagerOnly returns (bytes4, int128) {
        if (hookdata.length != 0 && msg.sender != address(this)) {
            HookData memory data = abi.decode(hookdata, (HookData));
            _autocompound(key, data);
        }

        return (this.afterSwap.selector, 0);
    }

    function _autocompound(PoolKey memory key, HookData memory params) internal {
        SwapAutoCompoundState memory state;
        int24 currentTick;
        (state.sqrtPriceX96, currentTick,,) = poolManager.getSlot0(key.toId());

        // if current tick is out of range. skip.
        if (currentTick < params.tickLower || currentTick > params.tickUpper) return;

        // Collect fee
        // Todo: reading fee deltas will reduce the additional modify call here.
        (state.earnedFeeDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: 0,
                salt: 0
            }),
            ""
        );

        // Todo: need to use auto swap here

        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            state.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            uint256(int256(state.earnedFeeDelta.amount0())),
            uint256(int256(state.earnedFeeDelta.amount1()))
        );

        (state.liquidityDelta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: int256(liquidity),
                salt: 0
            }),
            ""
        );

        state.liquidityDelta = state.earnedFeeDelta + state.liquidityDelta;

        int256 delta10 = state.liquidityDelta.amount0();
        int256 delta11 = state.liquidityDelta.amount1();

        if (delta10 > 0) key.currency0.take(poolManager, address(this), uint256(delta10), true);
        if (delta11 > 0) key.currency1.take(poolManager, address(this), uint256(delta11), true);
    }

    function _autoswap(SwapParams memory params) internal returns (BalanceDelta delta) {
        uint256 amount0 = params.amount0;
        uint256 amount1 = params.amount1;

        SwapState memory state;

        (state.positionAmount0, state.positionAmount1) = LiquidityAmounts.getAmountsForLiquidity(
            params.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(params.tickLower),
            TickMath.getSqrtPriceAtTick(params.tickUpper),
            Q96
        );

        uint256 priceX96 = (uint256(params.sqrtPriceX96) * uint256(params.sqrtPriceX96)) / Q96;

        // swap the fee tokens to the current price ratio.
        if (amount0 > 0 && amount1 > 0) {
            if (state.positionAmount0 == 0) {
                state.delta0 = amount0;
                state.sell0 = true;
            } else if (state.positionAmount1 == 0) {
                state.delta0 = (amount1 * Q96) / (priceX96);
                state.sell0 = false;
            } else {
                state.amountRatioX96 = (state.positionAmount0 * Q96) / state.positionAmount1;
                state.sell0 = (state.amountRatioX96 * amount1 < amount0 * Q96);
                if (state.sell0) {
                    state.delta0 = ((amount0 * Q96) - (state.amountRatioX96 * amount1))
                        / (((state.amountRatioX96 * priceX96) / Q96) + Q96);
                } else {
                    state.delta0 = ((state.amountRatioX96 * amount1) - (amount0 * Q96))
                        / (((state.amountRatioX96 * priceX96) / Q96) + Q96);
                }
            }

            if (state.delta0 > 0) {
                if (state.sell0) {
                    (state.swapDelta) = poolManager.swap(
                        params.key,
                        IPoolManager.SwapParams(true, state.delta0.toInt256(), TickMath.MIN_SQRT_PRICE + 1),
                        ""
                    );
                } else {
                    state.delta1 = (state.delta0 * priceX96) / Q96;
                    if (state.delta1 > 0) {
                        (state.swapDelta) = poolManager.swap(
                            params.key,
                            IPoolManager.SwapParams(false, state.delta1.toInt256(), TickMath.MAX_SQRT_PRICE - 1),
                            ""
                        );
                    }
                }
            }
        }

        return state.swapDelta;
    }
}
