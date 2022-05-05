// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.4;

import '../libraries/TickMath.sol';
import '../libraries/CurveMath.sol';

import "hardhat/console.sol";

interface UniswapV3Pool {
  function slot0 () external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex, uint16 observationCardinality, uint16 observationCardinalityNext, uint8 feeProtocol, bool unlocked);
}

contract FeeOracle {
  uint24 feeMin;
  uint24 feeMax;
  CurveMath.CurveState curve;
  UniswapV3Pool uniswapPool30;
  UniswapV3Pool uniswapPool5;

  constructor (uint24 _feeMin, uint24 _feeMax, CurveMath.CurveState memory _curve, address _uniswapPool30, address _uniswapPool5) {
    feeMin = _feeMin;
    feeMax = _feeMax;
    curve = _curve;
    uniswapPool30 = UniswapV3Pool(_uniswapPool30);
    uniswapPool5 = UniswapV3Pool(_uniswapPool5);
  }

  /// @notice Converts an integer into a Q64.64 fixed point representation.
  /// @param x A 64-bit unsigned integer to convert into Q64.64 format.
  function convQ64 (uint128 x) internal pure returns (uint128) {
    return x << 64;
  }

  /// @notice Converts a Q64.64 fixed point number into an integer by discarding all decimals.
  /// @param x A Q64.64 fixed point number to convert into a 64-bit integer
  function deconvQ64 (uint128 x) internal pure returns (uint128) {
    return x >> 64;
  }

  /// @notice Multiplies two Q64.64 fixed point numbers together, returning another Q64.64 number (result assumed to be below 2^63).
  /// @param a A Q64.64 fixed point number
  /// @param b A Q64.64 fixed point number
  function mulQ64 (uint128 a, uint128 b) internal pure returns (uint128) {
    return uint128((uint256(a) * uint256(b)) >> 64);
  }

  /// @notice Divides one Q64.64 fixed point number by another Q64.64 number.
  /// @param a A Q64.64 fixed point number (the numerator).
  /// @param b A Q64.64 fixed point number (the denominator).
  function divQ64 (uint128 a, uint128 b) internal pure returns (uint128) {
    uint256 a_ = uint256(a);
    a_ = a_ << 64;
    return uint128(a_ / b);
  }

  /// @notice Returns the current tick of the 30 basis point Uniswap reference pool.
  function getUniswapTick30 () private view returns (int24 tick) {
    (, tick, , , , ,) = uniswapPool30.slot0();
  }
  /// @notice Returns the current tick of the 5 basis point Uniswap reference pool.
  function getUniswapTick5 () private view returns (int24 tick) {
    (, tick, , , , ,) = uniswapPool5.slot0();
  }

  /// @notice Returns the price of the CrocSwap pool in square-root Q64.64 format.
  function getPoolSqrtPrice () private view returns (uint128) {
    return curve.priceRoot_;
  }

  /// @notice Returns the amount of liquidity active in the CrocSwap pool.
  function getPoolLiquidity () private view returns (uint128) {
    return CurveMath.activeLiquidity(curve);
  }

  /// @notice Calculates the optimal fee rate relative to a reference pool and assuming token0 is supplied by the trader. Uses a no-slippage approximation.
  /// @param refSqrtPrice Square root of the price of the reference pool, in Q64.64 fixed point format.
  /// @param poolSqrtPrice Square root of the price of the pool for which the fee is being calculated, in Q64.64 fixed point format.
  /// @param refFee Swap fee of the reference pool, in hundredths of basis points.
  function calculateDynamicFeeToken0In (uint128 refSqrtPrice, uint128 poolSqrtPrice, uint24 refFee) internal pure returns (uint24) {
    uint128 tmp = mulQ64(divQ64(refSqrtPrice, poolSqrtPrice), convQ64(1) - divQ64(convQ64(refFee), convQ64(200000000)));
    if (tmp > convQ64(1)) {
      return 0;
    } else {
      return uint24(deconvQ64(mulQ64((convQ64(1) - tmp) >> 1, convQ64(100000000))));
    }
  }

  /// @notice Calculates the optimal fee rate relative to a reference pool and assuming token1 is supplied by the trader. Uses a no-slippage approximation.
  /// @param refSqrtPrice Square root of the price of the reference pool, in Q64.64 fixed point format.
  /// @param poolSqrtPrice Square root of the price of the pool for which the fee is being calculated, in Q64.64 fixed point format.
  /// @param refFee Swap fee of the reference pool, in hundredths of basis points.
  function calculateDynamicFeeToken1In (uint128 refSqrtPrice, uint128 poolSqrtPrice, uint24 refFee) internal pure returns (uint24) {
    uint128 tmp = mulQ64(divQ64(poolSqrtPrice, refSqrtPrice), convQ64(1) - divQ64(convQ64(refFee), convQ64(200000000)));
    if (tmp > convQ64(1)) {
      return 0;
    } else {
      return uint24(deconvQ64(mulQ64((convQ64(1) - tmp) >> 1, convQ64(100000000))));
    }
  }

  /// @notice Calculates the no-slippage approximation of the dynamic fee relative to both the 30 and 5 basis point fee Uniswap reference pools, assuming swap provides token 0 as input, and returns the lower of the two fees.
  /// @param refSqrtPrice30 Square root of the price of the Uniswap 30 basis point reference pool, in Q64.64 fixed point format.
  /// @param refSqrtPrice30 Square root of the price of the Uniswap 5 basis point reference pool, in Q64.64 fixed point format.
  /// @param poolSqrtPrice Square root of the price of the pool for which the fee is being calculated, in Q64.64 fixed point format.
  function calculateBestDynamicFeeToken0In (uint128 refSqrtPrice30, uint128 refSqrtPrice5, uint128 poolSqrtPrice) internal pure returns (uint24) {
    uint24 fee30 = calculateDynamicFeeToken0In(refSqrtPrice30, poolSqrtPrice, 300000);
    uint24 fee5 = calculateDynamicFeeToken0In(refSqrtPrice5, poolSqrtPrice, 50000);
    return fee5 < fee30 ? fee5 : fee30;
  }

  /// @notice Calculates the no-slippage approximation of the dynamic fee relative to both the 30 and 5 basis point fee Uniswap reference pools, assuming swap provides token 1 as input, and returns the lower of the two fees.
  /// @param refSqrtPrice30 Square root of the price of the Uniswap 30 basis point reference pool, in Q64.64 fixed point format.
  /// @param refSqrtPrice30 Square root of the price of the Uniswap 5 basis point reference pool, in Q64.64 fixed point format.
  /// @param poolSqrtPrice Square root of the price of the pool for which the fee is being calculated, in Q64.64 fixed point format.
  function calculateBestDynamicFeeToken1In (uint128 refSqrtPrice30, uint128 refSqrtPrice5, uint128 poolSqrtPrice) internal pure returns (uint24) {
    uint24 fee30 = calculateDynamicFeeToken1In(refSqrtPrice30, poolSqrtPrice, 300000);
    uint24 fee5 = calculateDynamicFeeToken1In(refSqrtPrice5, poolSqrtPrice, 50000);
    return fee5 < fee30 ? fee5 : fee30;
  }

  /// @notice Calculates token quantity remaining after subtracting a given fee rate.
  /// @param tokenIn The quantity of token provided in the swap.
  /// @param fee The fee rate charged to the swap, in hundredths of basis points.
  function adjustTokenInForFee(uint128 tokenIn, uint128 fee) internal pure returns (uint128) {
    return ((100000000 - fee) * tokenIn) / 100000000;
  }

  /// @notice Calculates the new square-root price of the CrocSwap pool given an input quantity of token 0 and a fee rate, assuming active liquidity stays constant.
  /// @param tokenIn The quantity of token 0 provided in the swap.
  /// @param poolSqrtPrice The square rooted price of the CrocSwap pool, in Q64.64 fixed-point format.
  /// @param fee The fee rate charged to the swap, in hundredths of basis points.
  function estimateSqrtPriceToken0In (uint128 tokenIn, uint128 poolSqrtPrice, uint24 fee) private view returns (uint128) {
    tokenIn = adjustTokenInForFee(tokenIn, fee);
    uint128 invSqrtPrice = divQ64(convQ64(1), poolSqrtPrice);
    uint128 deltaInvSqrtPrice = divQ64(convQ64(tokenIn), convQ64(getPoolLiquidity()));
    uint128 newInvSqrtPrice = invSqrtPrice + deltaInvSqrtPrice;
    return divQ64(convQ64(1), newInvSqrtPrice);
  }

  /// @notice Calculates the new square-root price of the CrocSwap pool given an input quantity of token 1 and a fee rate, assuming active liquidity stays constant.
  /// @param tokenIn The quantity of token 1 provided by the swap.
  /// @param poolSqrtPrice The square rooted price of the CrocSwap pool, in Q64.64 fixed-point format.
  /// @param fee The fee rate charged to the swap, in hundredths of basis points.
  function estimateSqrtPriceToken1In (uint128 tokenIn, uint128 poolSqrtPrice, uint24 fee) private view returns (uint128) {
    tokenIn = adjustTokenInForFee(tokenIn, fee);
    uint128 deltaSqrtPrice = divQ64(convQ64(tokenIn), convQ64(getPoolLiquidity()));
    return poolSqrtPrice + deltaSqrtPrice;
  }

  /// @notice Given two square-rooted fixed-point Q64.64 prices, returns the absolute difference in hundredths of basis points relative to the first number.
  /// @param a The reference price relative to which the price difference is calculated, in square-root Q64.64 fixed-point format.
  /// @param b The price which is compared to the reference price, in square-root Q64.64 fixed-point format.
  function calculateSqrtPriceDifference (uint128 a, uint128 b) internal pure returns (uint24) {
    a = mulQ64(a, a);
    b = mulQ64(b, b);
    return uint24(deconvQ64(mulQ64(divQ64(b > a ? b - a : a - b, a), convQ64(100000000))));
  }

  /// @notice Given two price ticks, estimates the signed difference of the second price relative to the first price by simply taking the difference in tick space. The difference is given in hundredths of basis points.
  /// @param tick0 The reference tick relative to which the price difference is estimated.
  /// @param tick1 The price tick which is compared to the reference tick.
  function estimatePriceDifferenceWithTicks (int24 tick0, int24 tick1) internal pure returns (int24) {
    return (tick1 - tick0) * 100;
  }

  /// @notice Calculates absolute slippage in hundredths of basis points given an input quantity of token 0 and a fee rate, assuming active liquidity stays constant.
  /// @param tokenIn The quantity of token 0 provided by the swap.
  /// @param poolSqrtPrice The square rooted price of the pool, in Q64.64 fixed-point format.
  /// @param fee The fee rate charged to the swap, in hundredths of basis points.
  function estimateSlippageToken0In (uint128 tokenIn, uint128 poolSqrtPrice, uint24 fee) private view returns (uint24) {
    return calculateSqrtPriceDifference(poolSqrtPrice, estimateSqrtPriceToken0In(tokenIn, poolSqrtPrice, fee));
  }

  /// @notice Calculates absolute slippage in hundredths of basis points given an input quantity of token 1 and a fee rate, assuming active liquidity stays constant.
  /// @param tokenIn The quantity of token 1 provided by the swap.
  /// @param poolSqrtPrice The square rooted price of the pool, in Q64.64 fixed-point format.
  /// @param fee The fee rate charged to the swap, in hundredths of basis points.
  function estimateSlippageToken1In (uint128 tokenIn, uint128 poolSqrtPrice, uint24 fee) private view returns (uint24) {
    return calculateSqrtPriceDifference(poolSqrtPrice, estimateSqrtPriceToken1In(tokenIn, poolSqrtPrice, fee));
  }

  /// @notice Fully calculates the dynamic, per-swap fee with a multi-step process given a specific quantity of token inflow.
  /// @param token0 A boolean which is true if the token provided to the pool by the swap is token 0 in the pool's pair.
  /// @param tokenIn The quantity of token provided to the CrocSwap pool in a swap.
  function calculateDynamicFee (bool token0, uint128 tokenIn) public view returns (uint24 fee) {
    // Precompute the ticks and square-rooted Q64.64 prices of the two Uniswap reference pools and the CrocSwap pool under consideration
    int24 uniswapTick30 = getUniswapTick30();
    int24 uniswapTick5 = getUniswapTick5();
    uint128 uniswapSqrtPrice30 = TickMath.getSqrtRatioAtTick(uniswapTick30);
    uint128 uniswapSqrtPrice5 = TickMath.getSqrtRatioAtTick(uniswapTick5);
    uint128 poolSqrtPrice = getPoolSqrtPrice();
    int24 poolTick = TickMath.getTickAtSqrtRatio(poolSqrtPrice);

    // Calculate a no-slippage approximation of the optimal fee
    fee = token0 ? calculateBestDynamicFeeToken0In(uniswapSqrtPrice30, uniswapSqrtPrice5, poolSqrtPrice) : calculateBestDynamicFeeToken1In(uniswapSqrtPrice30, uniswapSqrtPrice5, poolSqrtPrice);

    // Calculate the slippage of executing the entire trade in the CrocSwap pool
    uint24 slippage = token0 ? estimateSlippageToken0In(tokenIn, poolSqrtPrice, fee) : estimateSlippageToken1In(tokenIn, poolSqrtPrice, fee);

    // Calculate the signed difference of the CrocSwap pool's price minus the Uniswap 30bp pool's price
    int24 priceDiff = estimatePriceDifferenceWithTicks(uniswapTick30, poolTick);
    priceDiff = token0 ? priceDiff : -priceDiff;

    // Adjust the slippage by adding the signed price difference between pools
    int24 slippage_ = int24(slippage) + priceDiff;
    slippage = slippage_ < 0 ? 0 : uint24(slippage_);

    // If slippage is higher than fee, use slippage as fee
    fee = slippage > fee ? slippage : fee;

    // Restrict fee to minimum and maximum values
    fee = fee < feeMin ? feeMin : fee;
    fee = fee > feeMax ? feeMax : fee;
  }
}