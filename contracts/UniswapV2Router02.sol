pragma solidity =0.6.6;

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';
// Router2仅在Router1上多了几个接口。为什么会有两个呢？
// 官方解释为：Router合约是无状态的并且不拥有任何代币，因此必要的时候它们可以安全升级。
// 当发现更高效的合约模式或者添加更多的功能时就可能升级它。因为这个原因，Router合约具有版本号，
// 从01开始，当前推荐的版本是02。
//那么Router1和Router2有什么区别呢？
//官方解释为：Router1中发现了一个低风险的bug，并且有些方法不支持使用转移的代币支付手续费，
// 所以不再使用Router1，推荐使用Router2。
contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint;
    // immutable，不可变的。类似别的语言的final变量。也就是它初始化后值就无法再改变了。
    // 它和constant（常量）类似，但又有些不同。主要区别在于：
    // 常量在编译时就是确定值，而immutable状态变量除了在定义的时候初始化外，
    // 还可以在构造器中初始化（合约创建的时候），并且在构造器中只能初始化，是读取不了它们的值的。
    // 并不是所有数据类型都可以为immutable变量或者常量的类型，当前只支持值类型和字符串类型(string)
    address public immutable override factory;
    address public immutable override WETH;
    // ensure构造器修饰符，判定当前区块（创建）时间不能超过最晚交易时间。
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }
    // 将上面两个immutable状态变量初始化。
    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }
    // 接下来是一个接收ETH的函数receive。从Solidity 0.6.0起，没有匿名回调函数了。
    // 它拆分成两个，一个专门用于接收ETH，就是这个receive函数。另外一个在找不到匹配的函数时调用，叫fallback函数。
    // 该receive函数限定只能从WETH合约直接接收ETH，也就是在WETH提取为ETH时。
    // 注意仍然有可以有别的方式来向此合约直接发送以太币，例如设置为矿工地址等。
    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }
    // _addLiquidity函数。看名字为增加流动性，为一个internal函数，提供给多个外部接口调用。
    // 它主要功能是计算拟向交易对合约注入的代币数量。
    // 该函数以下划线开头，根据约定一般它为一个内部函数。
    // 六个输入参数分别为交易对中两种代币的地址，计划注入的两种代币数量和注入代币的最小值（否则重置）。
    // 返回值为优化过的实际注入的代币数量。
    // **** ADD LIQUIDITY ****
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // 如果交易对不存在（获取的地址为零值），则创建。
        // create the pair if it doesn't exist yet
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }
        // 获取交易对资产池中两种代币reserve数量，当然如果是刚创建的，就都是0。
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
        // 1.如果是刚创建的交易对，则拟注入的代币全部转化为流动性，
        // 初始流动性计算公式及初始流动性燃烧于Pair合约中规定。
        // 如果交易对已经存在，由于注入的两种代币的比例和交易对中资产池中的代币比例可能不同，
        // 再用一个if - else语句来选择以哪种代币作为标准计算实际注入数量。
        // （如果比例不同，总会存在一种代币多一种代币少，肯定以代币少的计算实际注入数量）。
        // 2.以上可以这样理解，假定A/B交易对，然后注入了一定数量的A和B。
        // 根据交易对当前的比例，如果以A计算B，B不够，此时肯定不行；只能反过来，以B计算A，这样A就会有多余的，
        // 此时才能进行实际注入（这样注入的A和B数量都不会超过拟注入数量）。
        // 3.那为什么要按交易对的比例来注入两种代币呢？与在核心合约Pair中一样，
        // 流动性的增加数量是分别根据注入的两种代币的数量进行计算，然后取最小值。
        // 如果不按比例交易对比例来充，就会有一个较大值和一个较小值，取最小值流行性提供者就会有损失。
        // 如果按比例充，则两种代币计算的结果一样的，也就是理想值，不会有损失。
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
            if (amountBOptimal <= amountBDesired) {
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
                assert(amountAOptimal <= amountADesired);
                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }
    // 它是一个external函数，也就是用户调用的接口。
    // 函数参数和_addLiquidity函数类似，只是多了一个接收流动性代币的地址和最迟交易时间。
    // 这里deadline从UniswapV1就开始存在了，主要是保护用户，不让交易过了很久才执行，超过用户预期。
    // 函数返回值是实际注入的两种代币数量和得到的流动性代币数量。
    // 对于这个合约接口（外部函数），Uniswap文档也提到了三点注意事项：
    // 为了覆盖所有场景，调用者需要给该Router合约一定额度的两种代币授权。因为注入的资产为ERC20代币，
    // 第三方合约如果不得到授权（或者授权额度不够），就无法转移你的代币到交易对合约中去。
    // （就是说先授权给第三方合约可以转多少tokenA和tokenB，再由第三方合约去帮你转账，而不是你直接转入pair,毕竟该转多少是要算的）
    // 总是按理想的比例注入代币（因为计算比例和注入在一个交易内进行），具体取决于交易执行时的价格，
    // 这一点在介绍_addLiquidity函数时已经讲了。
    // 如果交易对不存在，则会自动创建，拟注入的代币数量就是真正注入的代币数量。
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 调用_addLiquidity函数计算需要向交易对合约转移（注入）的实际代币数量
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        // 获取交易对地址（注意，如果交易对不存在，在对_addLiquidity调用时会创建）。
        // 注意，它和_addLiquidity函数获取交易对地址略有不同，一个是调用factory合约的接口得到
        // （这里不能使用根据salt创建合约的方式计算得到，因为不管合约是否存在，总能得到该地址）；
        // 另一个是根据salt创建合约的方式计算得到。虽然两者用起来都没有问题，
        // 个人猜想本函数使用salt方式计算是因为调用的库函数是pure的，不读取状态变量，并且为内部调用，能节省gas；
        // 而调用factory合约接口是个外部EVM调用，有额外的开销。个人猜想，未必正确。
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 将实际注入的代币转移至交易对，授权给交易对转移代币的权利。
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        // 调用交易对合约的mint函数来给接收者增发流动性
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
    // 和addLiquidity函数类似，不过这里有一种初始注入资产为ETH。
    // 因为UniswapV2交易对都是ERC20交易对，所以注入ETH会先自动转换为等额WETH
    // （一种ERC20代币，通过智能合约自由兑换，比例1:1）。
    // 这样就满足了ERC20交易对的要求，因此真实交易对为WETH/ERC20交易对。
    // 注意这里没有拟注入的amountETHDesired，因为随本函数发送的ETH数量就是拟注入的数量，
    // 所以该函数必须是payable的，这样才可以接收以太币。
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 使用msg.value来代替拟注入的另一种代币（因为WETH与ETH是等额兑换）数量。
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
        // 将ETH兑换成WETH，它调用了WETH合约的兑换接口，这些接口在IWETH.sol中定义。
        // 兑换的数量也在第一行中计算得到。当然，如果ETH数量不够，则会重置整个交易。
        IWETH(WETH).deposit{value: amountETH}();
        // 将刚刚兑换的WETH转移至交易对合约，注意它直接调用的WETH合约，因此不是授权交易，不需要授权。
        // 另外由于WETH合约开源，可以看到该合约代码中转移资产成功后会返回一个true，所以使用了assert函数进行验证。
        //assert（断言）,与require相似，如果返回值不为true，则抛出异常
        // assert 和 require 区别在于，require 若失败则会返还给用户剩下的 gas， assert 则不会。
        // 所以大部分情况下，大家会比较喜欢 require，assert 只在代码可能出现严重错误的时候使用，比如 uint 溢出。
        assert(IWETH(WETH).transfer(pair, amountETH));
        liquidity = IUniswapV2Pair(pair).mint(to);
        // 如果调用进随本函数发送的ETH数量msg.value有多余的（大于amountETH,也就是兑换成WETH的数量），那么多余的ETH将退还给调用者。
        //因为这里是ETH直接转（而不是授权），然后再计算比例，所以会出现退款情况
        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // 移除（燃烧）流动性（代币），从而提取交易对中注入的两种代币。
    // 该函数的7个参数分别为两种代币地址，燃烧的流动性数量，提取的最小代币数量（保护用户），接收者地址和最迟交易时间。
    // 它的返回参数是提取的两种代币数量。该函数是virtual的，可被子合约重写。
    // 正如前面所讲，本合约是无状态的，是可以升级和替代的，因此本合约所有的函数都是virtual的，方便新合约重写它。
    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        // 计算两种代币的交易对地址，注意它是计算得来，而不是从factory合约查询得来
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 调用交易对合约的授权交易函数，将要燃烧的流动性转回交易对合约。
        // 如果该交易对不存在，则第一行代码计算出来的合约地址的代码长度就为0，
        // 调用其transferFrom函数就会报错重置整个交易，所以这里不用担心交易对不存在的情况。
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        // 调用交易对的burn函数，燃烧掉刚转过去的流动性代币，提取相应的两种代币给接收者。
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        // 将结果排下序（因为交易对返回的提取代币数量的前后顺序是按代币地址从小到大排序的），
        // 使输出参数匹配输入参数的顺序。
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        // 确保提取的数量不能小于用户指定的下限，否则重置交易。为什么会有这个保护呢，因为提取前可以存在多个交易，
        // 使交易对的两种代币比值（价格）和数量发生改变，从而达不到用户的预期值。
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
    // 同removeLiquidity函数类似，函数名多了ETH。
    // 它代表着用户希望最后接收到ETH，也就意味着该交易对必须为一个TOKEN/WETH交易对。
    // 只有交易对中包含了WETH代币，才能提取交易对资产池中的WETH，然后再将WETH兑换成ETH给接收者。
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        // 调用上一个函数removeLiquidity来进行流动性移除操作，只不过将提取资产的接收地址改成本合约。
        // 为什么呢？因为提取的是WETH，用户希望得到ETH，所以不能直接提取给接收者，还要多一步WETH/ETH兑换操作
        // 注意，在调用本合约的removeLiquidity函数过程中，msg.sender保持不变
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        // 第二行将燃烧流动性提取的另一种ERC20代币（非WETH）转移给接收者
        TransferHelper.safeTransfer(token, to, amountToken);
        // 将燃烧流动性提取的WETH换成ETH。
        IWETH(WETH).withdraw(amountETH);
        // 将兑换的ETH发送给接收者
        TransferHelper.safeTransferETH(to, amountETH);
    }
    // 同样也是移除流动性，同时提取交易对资产池中的两种ERC20代币。
    // 它和removeLiquidity函数的区别在于本函数支持使用线下签名消息来进行授权验证，
    // 从而不需要提前进行授权（这样会有一个额外交易），授权和交易均发生在同一个交易里。
    // 参考UniswapV2ERC20合约的permit函数
    // 和removeLiquidity函数相比，它输入参数多了bool approveMax及uint8 v, bytes32 r, bytes32 s。
    // approveMax的含义为是否授权为uint256最大值(2 ** 256 -1)，如果授权为最大值，在授权交易时有特殊处理，
    // 不再每次交易减少授权额度，相当于节省gas。v,r,s用来和重建后的签名消息一起验证签名者地址。

    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        // 计算交易对地址，注意不会为零地址。
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        // 根据是否为最大值设定授权额度。
        uint value = approveMax ? uint(-1) : liquidity;
        // 调用交易对合约的permit函数进行授权
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        // 调用removeLiquidity函数进行燃烧流动性从而提取代币的操作。
        // 因为在第三行代码里已经授权了，所以这里和前两个函数有区别，不需要用户提前进行授权了
        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }
    // 功能同removeLiquidityWithPermit类似，只不过将最后提取的资产由TOKEN变为ETH。
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // removeLiquidityETHSupportingFeeOnTransferTokens，它支持使用转移的代币支付手续费（支持包含此类代币交易对）。
    // 为什么会有使用转移的代币支付手续费这种提法呢？假定用户有某种代币，他想转给别人，
    // 但他还必须同时有ETH来支付手续费，也就是它需要有两种币，转的币和支付手续费的币，
    // 这就大大的提高了人们使用代币的门槛。于是有人想到，可不可以使用转移的代币来支付手续费呢？
    // 有人也做了一些探索，由此衍生了一种新类型的代币，ERC865代币，它也是ERC20代币的一个变种。
    // 然而本合约中的可支付转移手续费的代币却并未指明是ERC865代币，但是不管它是什么代币，我们可以简化为一点：
    // 此类代币在转移过程中可能发生损耗（损耗部分发送给第三方以支付整个交易的手续费），
    // 因此用户发送的代币数量未必就是接收者收到的代币数量
    // 将它的代码和removeLiquidityETH函数的代码相比较，只有稍微不同：
    // 1.函数返回参数及removeLiquidity函数返回值中没有了amountToken。
    //  因为它的一部分可能要支付手续费，所以removeLiquidity函数的返回值不再为当前接收到的代币数量。
    // 2.不管损耗多少，它把本合约接收到的所有此类TOKEN直接发送给接收者。
    // 3.WETH不是可支付转移手续费的代币，因此它不会有损耗。
    // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }
    // 功能同removeLiquidityETHSupportingFeeOnTransferTokens函数相同，但是支持使用链下签名消息进行授权。
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
    }
    function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }
    function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
        _swap(amounts, path, to);
        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');
        uint amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));
        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);
        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
        );
        _swapSupportingFeeOnTransferTokens(path, address(this));
        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // **** LIBRARY FUNCTIONS ****
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
