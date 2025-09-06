// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V3 interfaces
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
    function WETH9() external view returns (address);
}

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }
    
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

/**
 * @title V3Handler
 * @notice Handles Uniswap V3 and PancakeSwap V3 interactions for the aggregator
 * @dev Separate contract to keep main contracts under size limit
 */
contract V3Handler is AccessControl {
    using SafeERC20 for IERC20;
    
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    
    struct V3Router {
        address swapRouter;
        address quoter;
        bool isActive;
        uint24[] supportedFees; // [100, 500, 3000, 10000] = 0.01%, 0.05%, 0.3%, 1%
    }
    
    // Gas estimates for different V3 operations
    struct GasEstimates {
        uint256 singleHopGas;
        uint256 multiHopBaseGas;
        uint256 perHopGas;
    }
    
    mapping(bytes32 => V3Router) public v3Routers;
    bytes32[] public activeV3Routers;
    GasEstimates public gasEstimates;
    
    event V3SwapExecuted(
        bytes32 indexed routerKey,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        
        // Initialize default gas estimates (can be updated by admin)
        gasEstimates = GasEstimates({
            singleHopGas: 180000,
            multiHopBaseGas: 200000,
            perHopGas: 50000
        });
    }
    
    /**
     * @notice Execute V3 swap with single hop
     */
    function executeV3Swap(
        bytes32 routerKey,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256 amountOut) {
        V3Router memory router = v3Routers[routerKey];
        require(router.isActive, "Router not active");
        
        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Approve router
        SafeERC20.forceApprove(IERC20(tokenIn), router.swapRouter, amountIn);
        
        // Prepare swap params
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });
        
        // Execute swap
        amountOut = ISwapRouter(router.swapRouter).exactInputSingle(params);
        
        emit V3SwapExecuted(routerKey, tokenIn, tokenOut, amountIn, amountOut);
        
        // Reset approval
        SafeERC20.forceApprove(IERC20(tokenIn), router.swapRouter, 0);
    }
    
    /**
     * @notice Execute V3 multi-hop swap
     */
    function executeV3MultiHopSwap(
        bytes32 routerKey,
        bytes memory path, // Encoded path: token0, fee0, token1, fee1, token2...
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external onlyRole(EXECUTOR_ROLE) returns (uint256 amountOut) {
        V3Router memory router = v3Routers[routerKey];
        require(router.isActive, "Router not active");
        
        // Decode first token from path for approval
        address tokenIn;
        assembly {
            tokenIn := mload(add(path, 0x20))
        }
        
        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Approve router
        SafeERC20.forceApprove(IERC20(tokenIn), router.swapRouter, amountIn);
        
        // Prepare swap params
        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: recipient,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: amountOutMinimum
        });
        
        // Execute swap
        amountOut = ISwapRouter(router.swapRouter).exactInput(params);
        
        // Reset approval
        SafeERC20.forceApprove(IERC20(tokenIn), router.swapRouter, 0);
        
        return amountOut;
    }
    
    /**
     * @notice Execute native ETH to token swap on V3
     */
    function executeV3ETHSwap(
        bytes32 routerKey,
        address tokenOut,
        uint24 fee,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external payable onlyRole(EXECUTOR_ROLE) returns (uint256 amountOut) {
        V3Router memory router = v3Routers[routerKey];
        require(router.isActive, "Router not active");
        
        address weth = ISwapRouter(router.swapRouter).WETH9();
        
        // Prepare swap params
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            deadline: deadline,
            amountIn: msg.value,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });
        
        // Execute swap with ETH
        amountOut = ISwapRouter(router.swapRouter).exactInputSingle{value: msg.value}(params);
        
        emit V3SwapExecuted(routerKey, weth, tokenOut, msg.value, amountOut);
    }
    
    /**
     * @notice Get quote for V3 swap
     */
    function getV3Quote(
        bytes32 routerKey,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn
    ) external returns (uint256 amountOut, uint256 gasEstimate) {
        V3Router memory router = v3Routers[routerKey];
        require(router.quoter != address(0), "Quoter not set");
        
        IQuoterV2.QuoteExactInputSingleParams memory params = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            fee: fee,
            sqrtPriceLimitX96: 0
        });
        
        (amountOut, , , gasEstimate) = IQuoterV2(router.quoter).quoteExactInputSingle(params);
    }
    
    /**
     * @notice Find best fee tier for a V3 pair
     */
    function findBestV3Fee(
        bytes32 routerKey,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint24 bestFee, uint256 bestOutput) {
        V3Router memory router = v3Routers[routerKey];
        require(router.quoter != address(0), "Quoter not set");
        
        for (uint256 i = 0; i < router.supportedFees.length; i++) {
            uint24 fee = router.supportedFees[i];
            
            try IQuoterV2(router.quoter).quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amountIn: amountIn,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            ) returns (uint256 amountOut, uint160, uint32, uint256) {
                if (amountOut > bestOutput) {
                    bestOutput = amountOut;
                    bestFee = fee;
                }
            } catch {
                // Pool doesn't exist for this fee tier
                continue;
            }
        }
    }
    
    /**
     * @notice Get comprehensive V3 quote with gas estimation
     */
    function getV3QuoteWithGas(
        bytes32 routerKey,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (
        uint24 bestFee,
        uint256 bestOutput,
        uint256 gasEstimate
    ) {
        (bestFee, bestOutput) = this.findBestV3Fee(routerKey, tokenIn, tokenOut, amountIn);
        gasEstimate = gasEstimates.singleHopGas; // Use dynamic gas estimate
    }
    
    /**
     * @notice Get gas estimate for multi-hop V3 swap
     */
    function getV3MultiHopGasEstimate(uint256 hopCount) public view returns (uint256) {
        return gasEstimates.multiHopBaseGas + (gasEstimates.perHopGas * hopCount);
    }
    
    // --- ADMIN FUNCTIONS ---
    
    function addV3Router(
        bytes32 key,
        address swapRouter,
        address quoter,
        uint24[] memory supportedFees
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(swapRouter != address(0), "Invalid router");
        require(v3Routers[key].swapRouter == address(0), "Router exists");
        
        v3Routers[key] = V3Router({
            swapRouter: swapRouter,
            quoter: quoter,
            isActive: true,
            supportedFees: supportedFees
        });
        
        activeV3Routers.push(key);
    }
    
    function updateV3Router(
        bytes32 key,
        bool isActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(v3Routers[key].swapRouter != address(0), "Router not found");
        v3Routers[key].isActive = isActive;
    }
    
    function grantExecutorRole(address executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        grantRole(EXECUTOR_ROLE, executor);
    }
    
    function updateGasEstimates(
        uint256 _singleHopGas,
        uint256 _multiHopBaseGas,
        uint256 _perHopGas
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_singleHopGas > 0 && _singleHopGas < 1000000, "Invalid single hop gas");
        require(_multiHopBaseGas > 0 && _multiHopBaseGas < 2000000, "Invalid multi hop base gas");
        require(_perHopGas > 0 && _perHopGas < 500000, "Invalid per hop gas");
        
        gasEstimates = GasEstimates({
            singleHopGas: _singleHopGas,
            multiHopBaseGas: _multiHopBaseGas,
            perHopGas: _perHopGas
        });
    }
    
    // Emergency functions
    function emergencyWithdrawToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
    
    function emergencyWithdrawETH() external onlyRole(DEFAULT_ADMIN_ROLE) {
        payable(msg.sender).transfer(address(this).balance);
    }
    
    receive() external payable {}
}