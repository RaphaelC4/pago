// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20B {
    function approve(address spender, uint256 amount) external;
    function balanceOf(address owner) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IPoolB {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0Delta, int256 amount1Delta);
}

/// Uniswap V3 swaps must be SENT BY A CONTRACT: the pool transfers the bought
/// tokens first, then calls `uniswapV3SwapCallback` on `msg.sender`, and a
/// call to an address with no code reverts with empty data (forge reports it
/// as "call to non-contract address"). Proved directly by the quote test: the
/// EOA swap moved the BEM and then died on the callback.
///
/// Minimal stand-in for a swap router. It holds no funds of its own and is
/// built to be safe while the payer's WOKB allowance is live, because that
/// allowance is the one real drain vector in this flow:
///
///   1. `onlyPayer` - `buy()` reverts for anyone but the funding wallet, so
///      nobody can spend the allowance on a swap that sends the BEM to them.
///   2. `maxIn` - an input-side slippage cap held for the duration of one
///      swap and cleared on return: the pool may pull at most this much WOKB,
///      whatever the output-side price limit says. The caller quotes it from
///      the spot price before sending.
///   3. shape check - the callback only ever accepts "pool paid BEM out,
///      pool is owed WOKB". Any other shape is a swap this flow never
///      approved, and fails loud.
///
/// The caller approves EXACTLY `maxIn` (never `type(uint256).max`), asserts
/// the buyer is empty afterwards, and revokes the allowance to 0.
///
/// Lives under `script/`, not `src/`: `contracts-evm/src/` is frozen at the
/// beacon-wording fix and must not gain files. The quote test imports THIS
/// file, so the artifact under test is the artifact that gets deployed.
contract BemBuyer {
    error NotThePool();
    error UnexpectedSwapShape();
    error NotThePayer();
    error InputOverCap();

    address immutable pool;
    address immutable wokb;
    address immutable payer;

    /// Input-side cap for the swap in flight. Set by `buy()` before the pool
    /// call and cleared when it returns, so a stale cap can never be reused.
    uint256 public maxIn;

    constructor(address pool_, address wokb_, address payer_) {
        pool = pool_;
        wokb = wokb_;
        payer = payer_;
    }

    /// Exact-output buy of `amountOut` BEM (token0), paid in WOKB (token1).
    /// `amountOut` is negative in Uniswap V3's exact-output convention.
    function buy(address recipient, int256 amountOut, uint160 sqrtPriceLimitX96, uint256 maxIn_)
        external
        returns (int256 amount0Delta, int256 amount1Delta)
    {
        if (msg.sender != payer) revert NotThePayer();
        maxIn = maxIn_;
        (amount0Delta, amount1Delta) = IPoolB(pool).swap(recipient, false, amountOut, sqrtPriceLimitX96, "");
        maxIn = 0;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != pool) revert NotThePool();
        // token0 = BEM, token1 = WOKB. A buy pays BEM OUT (negative delta)
        // and is owed WOKB (positive delta); the reverse shape would mean the
        // pool is paying US in WOKB and taking BEM - a swap this contract was
        // never asked to make.
        if (amount0Delta > 0 || amount1Delta < 0) revert UnexpectedSwapShape();
        if (amount1Delta > 0) {
            if (uint256(amount1Delta) > maxIn) revert InputOverCap();
            if (!IERC20B(wokb).transferFrom(payer, pool, uint256(amount1Delta))) revert UnexpectedSwapShape();
        }
    }

    /// True when the buyer holds nothing of `token`. The caller asserts this
    /// after every swap: bought BEM goes straight to the recipient, and the
    /// owed WOKB goes straight to the pool, so the buyer must end at zero.
    function isEmpty(address token) external view returns (bool) {
        return IERC20B(token).balanceOf(address(this)) == 0;
    }
}
