// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {Deployers} from "v4-core-test/utils/Deployers.sol";

import {AutoCompound} from "../src/AutoCompound.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";

import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {PoolIdLibrary, PoolId} from "v4-core/types/PoolId.sol";

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {Position} from "v4-core/libraries/Position.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

contract AutoCompoundTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    AutoCompound hook;

    event Swap(
        PoolId indexed poolId,
        address sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick,
        uint24 fee
    );

    struct HookData {
        int24 tickLower;
        int24 tickUpper;
    }

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG));

        deployCodeTo("AutoCompound.sol", abi.encode(manager), hookAddress);

        hook = AutoCompound(hookAddress);

        (key,) = initPool(currency0, currency1, hook, 3000, 60, SQRT_PRICE_1_1, ZERO_BYTES);

        // Add some initial liquidity
        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, 1000 ether);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, 1000 ether);

        hook.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: 0})
        );
        hook.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10 ether, salt: 0})
        );
    }

    function test_checkLiquidity() public view {
        uint128 liquidity = manager.getLiquidity(key.toId());
        assertEq(liquidity, 20 ether);
    }

    function test_userLiquidity() public view {
        int256 userLiquidity = hook.getUserLiquidity(address(this), key, -60, 60, 0);
        assertEq(userLiquidity, 10 ether);
    }

    function test_swap() public {
        IPoolManager.SwapParams memory sparams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, sparams, testSettings, ZERO_BYTES);

        sparams =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 10000, sqrtPriceLimitX96: SQRT_PRICE_2_1});

        swapRouter.swap(key, sparams, testSettings, abi.encode(HookData(-60, 60)));

        int256 userLiquidity = hook.getUserLiquidity(address(this), key, -60, 60, 0);

        assertGt(userLiquidity, 10 ether);
    }

    function test_add_liquidity_autocompound() public {
        IPoolManager.SwapParams memory sparams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, sparams, testSettings, ZERO_BYTES);

        hook.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: 0})
        );

        int256 userLiquidity = hook.getUserLiquidity(address(this), key, -60, 60, 0);

        assertGt(userLiquidity, 10 ether);
    }

    function test_remove_liquidity_autocompound() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory sparams =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 10000, sqrtPriceLimitX96: SQRT_PRICE_2_1});

        swapRouter.swap(key, sparams, testSettings, ZERO_BYTES);

        hook.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -5 ether, salt: 0})
        );

        int256 userLiquidity = hook.getUserLiquidity(address(this), key, -60, 60, 0);

        assertLt(userLiquidity, 6 ether);
    }

    function test_remove_all() public {
        IPoolManager.SwapParams memory sparams =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, sparams, testSettings, ZERO_BYTES);

        hook.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: 0})
        );

        int256 userLiquidity = hook.getUserLiquidity(address(this), key, -60, 60, 0);

        hook.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -userLiquidity, salt: 0})
        );
    }
}
