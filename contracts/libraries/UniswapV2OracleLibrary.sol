pragma solidity >=0.5.0;
//下面两行导入语句分别导入交易对合约接口和自定义的浮点数库
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
//该库并不是以编写源码的方式保存为文件直接导入的，而是通过Node.js模块导入，属于依赖库。
// 查看其周边合约的README.md可以看到，运行yarn命令来安装所有依赖。
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

// library with helper methods for oracles that are concerned with computing average prices
library UniswapV2OracleLibrary {
    // 在所有数据类型上使用FixedPoint库，从中可以看出库中也可以使用别的库，语法是一样的。
    using FixedPoint for *;

    // 获取当前区块时间，注意这里和交易对合约中的处理方式一样，取模操作。
    // 然而就算溢出了，直接进行类型转换也会得到和取模操作相同的值。这个问题与核心合约中相同。
    // helper function that returns the current block timestamp within the range of uint32, i.e. [0, 2**32 - 1]
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }
    // 计算当前区块累积价格。如果当前区块交易对合约已经计算过了（两个区块时间一致），则跳过；如果没有，则加上去。
    // 注意它是view函数，并未更新任何状态变量，这个累计值是计算出来的。
    // produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
    function currentCumulativePrices(
        address pair
    ) internal view returns (uint price0Cumulative, uint price1Cumulative, uint32 blockTimestamp) {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // if time has elapsed since the last update on the pair, mock the accumulated price values
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        if (blockTimestampLast != blockTimestamp) {
            // subtraction overflow is desired
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // addition overflow is desired
            // counterfactual
            price0Cumulative += uint(FixedPoint.fraction(reserve1, reserve0)._x) * timeElapsed;
            // counterfactual
            price1Cumulative += uint(FixedPoint.fraction(reserve0, reserve1)._x) * timeElapsed;
        }
    }
}
