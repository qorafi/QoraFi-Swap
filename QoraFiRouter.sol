// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// --- INTERFACES ---

interface IPancakeRouter02 {
    function WETH() external view returns (address);
    function factory() external view returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable returns (uint[] memory amounts);
    function swapExactTokensForTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);
}

// --- MAIN CONTRACT ---

/**
 * @title QoraFiRouter (Aggregator Version)
 * @author Gemini
 * @notice A DEX aggregator that finds the best swap rates across multiple routers and takes a fee.
 * @dev All administrative functions are intended to be controlled by a DAO/Timelock.
 */
contract QoraFiRouter is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROUTER_MANAGER_ROLE = keccak256("ROUTER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STRUCTS ---
    struct RouterInfo {
        IPancakeRouter02 router;
        uint256 successfulSwaps;
        uint256 failedQuotes;
    }

    // --- STATE VARIABLES ---
    mapping(bytes32 => RouterInfo) public routerInfo;
    bytes32[] public routerKeys;
    mapping(bytes32 => uint256) private routerKeyIndex; // For O(1) removal
    
    address public WBNB;
    address public treasuryWallet;
    uint256 public feePercentBps;

    // MEV Protection
    mapping(address => uint256) private lastSwapBlock;

    // --- CONSTANTS ---
    bytes32 private constant INITIAL_ROUTER_KEY = "PancakeSwapV2";

    // --- EVENTS ---
    event RouterAdded(bytes32 indexed key, address indexed routerAddress);
    event RouterRemoved(bytes32 indexed key);
    event TreasuryWalletUpdated(address indexed newTreasury);
    event FeePercentUpdated(uint256 newFeePercentBps);
    event SwapFeeCollected(address indexed user, address indexed tokenIn, uint256 feeAmount);
    event WithdrewStuckAssets(address indexed token, address indexed to, uint256 amount);
    event SwapExecuted(address indexed user, bytes32 indexed routerKey, address[] path, uint256 amountIn, uint256 amountOut);

    // --- ERRORS ---
    error DeadlineExpired();
    error InsufficientOutputAmount();
    error AmountToSwapIsZero();
    error FailedToSendFee();
    error RouterKeyAlreadyExists();
    error RouterDoesNotExist();
    error InvalidRouter();
    error NoRoutersConfigured();
    error NoQuoteAvailable();
    error MultipleSwapsInSameBlock();

    /**
     * @param _initialRouterAddress The address of the primary DEX router (e.g., PancakeSwap V2).
     * @param _initialTreasuryWallet The address where protocol fees will be sent.
     * @param _initialFeePercentBps The initial fee in basis points (e.g., 25 for 0.25%). Max 100 (1%).
     */
    constructor(
        address _initialRouterAddress,
        address _initialTreasuryWallet,
        uint256 _initialFeePercentBps
    ) {
        require(_initialRouterAddress != address(0), "QoraFiRouter: Router address cannot be zero");
        require(_initialTreasuryWallet != address(0), "QoraFiRouter: Treasury wallet cannot be zero");
        require(_initialFeePercentBps <= 100, "QoraFiRouter: Initial fee cannot exceed 1%");

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(ROUTER_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        IPancakeRouter02 initialRouter = IPancakeRouter02(_initialRouterAddress);
        routerInfo[INITIAL_ROUTER_KEY].router = initialRouter;
        routerKeys.push(INITIAL_ROUTER_KEY);
        routerKeyIndex[INITIAL_ROUTER_KEY] = routerKeys.length;
        
        WBNB = initialRouter.WETH();
        treasuryWallet = _initialTreasuryWallet;
        feePercentBps = _initialFeePercentBps;

        emit RouterAdded(INITIAL_ROUTER_KEY, _initialRouterAddress);
        emit TreasuryWalletUpdated(_initialTreasuryWallet);
        emit FeePercentUpdated(_initialFeePercentBps);
    }

    // --- MODIFIERS ---
    /**
     * @dev Prevents the same EOA from executing multiple swaps in the same block.
     * A basic but effective MEV mitigation strategy.
     */
    modifier antiMEV() {
        require(lastSwapBlock[tx.origin] < block.number, "Multiple swaps in same block");
        _;
        lastSwapBlock[tx.origin] = block.number;
    }

    // --- CORE SWAP FUNCTIONS ---

    /**
     * @notice Swaps an exact amount of BNB for tokens, aggregating across known routers for the best price.
     * @param _amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param _path The swap path (e.g., [WBNB, TokenOut]).
     * @param _to The recipient of the output tokens.
     * @param _deadline A Unix timestamp after which the transaction will revert.
     */
    function swapExactBNBForTokensWithFee(
        uint256 _amountOutMin, address[] calldata _path, address _to, uint256 _deadline
    ) external payable nonReentrant whenNotPaused antiMEV {
        if (block.timestamp > _deadline) revert DeadlineExpired();

        (IPancakeRouter02 bestRouter, uint256 bestAmountOut) = findBestRoute(_path, msg.value);
        uint256 expectedAfterFee = (bestAmountOut * (10000 - feePercentBps)) / 10000;
        if (expectedAfterFee < _amountOutMin) revert InsufficientOutputAmount();

        uint256 feeAmount = (msg.value * feePercentBps) / 10000;
        uint256 amountToSwap = msg.value - feeAmount;
        if (amountToSwap == 0) revert AmountToSwapIsZero();

        (bool success, ) = payable(treasuryWallet).call{value: feeAmount}("");
        if (!success) revert FailedToSendFee();
        emit SwapFeeCollected(msg.sender, WBNB, feeAmount);

        bytes32 routerKey = _findRouterKey(address(bestRouter));
        routerInfo[routerKey].successfulSwaps++;
        uint256[] memory amounts = bestRouter.swapExactETHForTokens{value: amountToSwap}(_amountOutMin, _path, _to, _deadline);
        emit SwapExecuted(_to, routerKey, _path, amountToSwap, amounts[amounts.length - 1]);
    }

    /**
     * @notice Swaps an exact amount of tokens for other tokens, aggregating for the best price.
     * @param _amountIn The exact amount of input tokens.
     * @param _amountOutMin The minimum amount of output tokens that must be received.
     * @param _path The swap path (e.g., [TokenIn, TokenOut]).
     * @param _to The recipient of the output tokens.
     * @param _deadline A Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokensWithFee(
        uint256 _amountIn, uint256 _amountOutMin, address[] calldata _path, address _to, uint256 _deadline
    ) external nonReentrant whenNotPaused antiMEV {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        
        (IPancakeRouter02 bestRouter, uint256 bestAmountOut) = findBestRoute(_path, _amountIn);
        uint256 expectedAfterFee = (bestAmountOut * (10000 - feePercentBps)) / 10000;
        if (expectedAfterFee < _amountOutMin) revert InsufficientOutputAmount();

        address tokenIn = _path[0];
        IERC20 inputToken = IERC20(tokenIn);
        
        inputToken.safeTransferFrom(msg.sender, address(this), _amountIn);

        uint256 feeAmount = (_amountIn * feePercentBps) / 10000;
        uint256 amountToSwap = _amountIn - feeAmount;
        if (amountToSwap == 0) revert AmountToSwapIsZero();
        
        inputToken.safeTransfer(treasuryWallet, feeAmount);
        emit SwapFeeCollected(msg.sender, tokenIn, feeAmount);
        
        bytes32 routerKey = _findRouterKey(address(bestRouter));
        inputToken.safeIncreaseAllowance(address(bestRouter), amountToSwap);
        try bestRouter.swapExactTokensForTokens(amountToSwap, _amountOutMin, _path, _to, _deadline) returns (uint256[] memory amounts) {
            inputToken.safeDecreaseAllowance(address(bestRouter), amountToSwap);
            routerInfo[routerKey].successfulSwaps++;
            emit SwapExecuted(_to, routerKey, _path, amountToSwap, amounts[amounts.length - 1]);
        } catch {
            inputToken.safeDecreaseAllowance(address(bestRouter), amountToSwap);
            revert("Swap failed");
        }
    }
    
    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    /** @notice Pauses or unpauses the contract's swap functions. */
    function setPaused(bool _paused) external onlyRole(PAUSER_ROLE) {
        if (_paused) _pause();
        else _unpause();
    }

    /** @notice Adds a new DEX router to the aggregator. */
    function addRouter(bytes32 _key, address _routerAddress) external onlyRole(ROUTER_MANAGER_ROLE) {
        if (_routerAddress == address(0)) revert InvalidRouter();
        if (address(routerInfo[_key].router) != address(0)) revert RouterKeyAlreadyExists();
        
        IPancakeRouter02 newRouter = IPancakeRouter02(_routerAddress);
        require(newRouter.WETH() == WBNB, "Router must be on the same chain (WBNB mismatch)");
        
        routerInfo[_key].router = newRouter;
        routerKeys.push(_key);
        routerKeyIndex[_key] = routerKeys.length;
        emit RouterAdded(_key, _routerAddress);
    }

    /** @notice Removes a DEX router from the aggregator. */
    function removeRouter(bytes32 _key) external onlyRole(ROUTER_MANAGER_ROLE) {
        uint256 index = routerKeyIndex[_key];
        if (index == 0) revert RouterDoesNotExist();
        
        uint256 indexToRemove = index - 1;
        bytes32 lastKey = routerKeys[routerKeys.length - 1];

        routerKeys[indexToRemove] = lastKey;
        routerKeyIndex[lastKey] = index;
        
        routerKeys.pop();
        delete routerKeyIndex[_key];
        delete routerInfo[_key];
        
        emit RouterRemoved(_key);
    }

    /** @notice Updates the treasury wallet address. */
    function setTreasuryWallet(address _newTreasuryWallet) external onlyRole(GOVERNANCE_ROLE) {
        require(_newTreasuryWallet != address(0), "Treasury wallet cannot be zero");
        treasuryWallet = _newTreasuryWallet;
        emit TreasuryWalletUpdated(_newTreasuryWallet);
    }

    /** @notice Updates the fee percentage. Max 100 BPS (1%). */
    function setFeePercent(uint256 _newFeePercentBps) external onlyRole(GOVERNANCE_ROLE) {
        require(_newFeePercentBps <= 100, "Fee cannot exceed 1%");
        feePercentBps = _newFeePercentBps;
        emit FeePercentUpdated(_newFeePercentBps);
    }

    /** @notice Recovers any ERC20 tokens accidentally sent to this contract. */
    function withdrawStuckTokens(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        IERC20 token = IERC20(_tokenAddress);
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(treasuryWallet, amount);
        emit WithdrewStuckAssets(_tokenAddress, treasuryWallet, amount);
    }

    /** @notice Recovers any BNB accidentally sent to this contract. */
    function withdrawStuckBNB() external onlyRole(GOVERNANCE_ROLE) {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB to withdraw");
        (bool success, ) = payable(treasuryWallet).call{value: balance}("");
        require(success, "BNB withdrawal failed");
        emit WithdrewStuckAssets(WBNB, treasuryWallet, balance);
    }
    
    // --- VIEW & QUOTE FUNCTIONS ---
    
    /**
     * @notice Finds the best swap route across all registered DEXs.
     * @return bestRouter The address of the router offering the best price.
     * @return bestAmountOut The best output amount found.
     */
    function findBestRoute(address[] calldata path, uint256 amountIn) public view returns (IPancakeRouter02 bestRouter, uint256 bestAmountOut) {
        uint256 len = routerKeys.length;
        if (len == 0) revert NoRoutersConfigured();
        bestAmountOut = 0;
        
        for (uint i = 0; i < len; i++) {
            bytes32 key = routerKeys[i];
            IPancakeRouter02 currentRouter = routerInfo[key].router;
            try currentRouter.getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
                uint256 currentAmountOut = amounts[amounts.length - 1];
                if (currentAmountOut > bestAmountOut) {
                    bestAmountOut = currentAmountOut;
                    bestRouter = currentRouter;
                }
            } catch {
                // This is a mutable operation, but it's safe in a view function context
                // as it only affects the returned data, not state.
                // For a fully compliant solution, this would be moved to a state-changing function.
                // routerInfo[key].failedQuotes++; 
                continue;
            }
        }
        if (address(bestRouter) == address(0)) revert NoQuoteAvailable();
    }

    /** @notice Gets a quote for a swap without executing it. */
    function quoteSwap(address[] calldata path, uint256 amountIn) external view returns (uint256 amountOut) {
        (, amountOut) = findBestRoute(path, amountIn);
    }
    
    /** @notice Internal function to find the key for a given router address. */
    function _findRouterKey(address _routerAddress) internal view returns (bytes32) {
        uint256 len = routerKeys.length;
        for (uint i = 0; i < len; i++) {
            if (address(routerInfo[routerKeys[i]].router) == _routerAddress) {
                return routerKeys[i];
            }
        }
        return "UnknownRouter";
    }
    
    receive() external payable {}
}
