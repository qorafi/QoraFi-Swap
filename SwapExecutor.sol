// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ISwapExecutor.sol";
import "../libraries/SwapUtilities.sol";

/**
 * @title SwapExecutor
 * @notice Handles swap execution for QoraFi aggregator
 * @dev Separated from aggregator to reduce contract size
 */
contract SwapExecutor is ISwapExecutor, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant AGGREGATOR_ROLE = keccak256("AGGREGATOR_ROLE");
    
    address public immutable WBNB;
    address public feeCollector;
    uint16 public protocolFeeBps;
    address public v3Handler; // Optional V3 handler contract
    
    mapping(address => bool) public approvedRouters;
    mapping(address => uint256) public routerNonces;
    
    // MEV Protection
    mapping(address => uint256) public lastBlockTraded; // Track last block per user
    mapping(address => bool) public trustedContracts;
    bool public mevProtectionEnabled;
    
    event SwapExecuted(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    
    event FeeCollected(address token, uint256 amount);
    event RouterApproved(address router, bool approved);
    
    modifier onlyApprovedRouter(address router) {
        require(approvedRouters[router], "Router not approved");
        _;
    }
    
    modifier withMEVProtection() {
        if (mevProtectionEnabled) {
            // Prevent contract calls unless whitelisted (stops MEV bots)
            if (msg.sender != tx.origin) {
                require(trustedContracts[msg.sender], "Untrusted contract");
            }
            
            // Prevent multiple transactions in same block (stops sandwich attacks)
            require(lastBlockTraded[tx.origin] < block.number, "One trade per block");
            lastBlockTraded[tx.origin] = block.number;
        }
        _;
    }
    
    constructor(address _wbnb, address _feeCollector) {
        require(_wbnb != address(0) && _feeCollector != address(0), "Invalid address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EXECUTOR_ROLE, msg.sender);
        
        WBNB = _wbnb;
        feeCollector = _feeCollector;
        protocolFeeBps = 10; // 0.1%
        
        // Enable MEV protection by default
        mevProtectionEnabled = true;
    }
    
    /**
     * @notice Execute token to token swap
     */
    function executeSwap(SwapParams calldata params) 
        external 
        override
        nonReentrant 
        whenNotPaused
        onlyApprovedRouter(params.router)
        withMEVProtection()
        returns (uint256 amountOut) 
    {
        require(params.deadline >= block.timestamp, "Deadline passed");
        require(params.amountIn > 0, "Invalid amount");
        
        // Transfer tokens from sender
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        
        // Approve router if needed
        _ensureApproval(params.tokenIn, params.router, params.amountIn);
        
        // Execute swap
        if (params.path.length == 2) {
            // Direct swap
            amountOut = SwapLib.executeSwap(
                params.router,
                params.tokenIn,
                params.tokenOut,
                params.amountIn,
                params.minAmountOut,
                params.deadline
            );
        } else {
            // Multi-hop swap - use path[0] and path[length-1] as tokenIn and tokenOut
            amountOut = SwapLib.executeMultiHopSwap(
                params.router,
                params.path[0],  // tokenIn
                params.path[params.path.length - 1],  // tokenOut
                params.amountIn,
                params.minAmountOut,
                params.deadline
            );
        }
        
        // Transfer output to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
        
        emit SwapExecuted(msg.sender, params.tokenIn, params.tokenOut, params.amountIn, amountOut);
    }
    
    /**
     * @notice Execute swap with protocol fee
     */
    function executeSwapWithFee(SwapParams calldata params, uint256 feeAmount) 
        external 
        override
        nonReentrant
        whenNotPaused
        onlyRole(AGGREGATOR_ROLE)
        returns (uint256 amountOut) 
    {
        require(params.deadline >= block.timestamp, "Deadline passed");
        
        // Transfer tokens from sender
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        
        // Collect fee if specified
        uint256 swapAmount = params.amountIn;
        if (feeAmount > 0) {
            require(feeAmount <= params.amountIn * protocolFeeBps / 10000, "Excessive fee");
            IERC20(params.tokenIn).safeTransfer(feeCollector, feeAmount);
            swapAmount = params.amountIn - feeAmount;
            emit FeeCollected(params.tokenIn, feeAmount);
        }
        
        // Approve router
        _ensureApproval(params.tokenIn, params.router, swapAmount);
        
        // Execute swap
        if (params.path.length == 2) {
            amountOut = SwapLib.executeSwap(
                params.router,
                params.tokenIn,
                params.tokenOut,
                swapAmount,
                params.minAmountOut,
                params.deadline
            );
        } else {
            amountOut = SwapLib.executeMultiHopSwap(
                params.router,
                params.path[0],  // tokenIn
                params.path[params.path.length - 1],  // tokenOut
                swapAmount,
                params.minAmountOut,
                params.deadline
            );
        }
        
        // Transfer to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
        
        emit SwapExecuted(msg.sender, params.tokenIn, params.tokenOut, swapAmount, amountOut);
    }
    
    /**
     * @notice Execute native BNB to token swap
     */
    function executeNativeSwap(NativeSwapParams calldata params) 
        external 
        payable
        override
        nonReentrant
        whenNotPaused
        onlyApprovedRouter(params.router)
        withMEVProtection()
        returns (uint256 amountOut) 
    {
        require(params.deadline >= block.timestamp, "Deadline passed");
        require(msg.value > 0, "No BNB sent");
        
        if (params.path.length == 2) {
            // Direct BNB to token
            amountOut = SwapLib.executeETHToTokenSwap(
                params.router,
                params.tokenOut,
                msg.value,
                params.minAmountOut,
                params.deadline
            );
        } else {
            // Multi-hop starting with BNB
            amountOut = SwapLib.executeMultiHopETHToTokenSwap(
                params.router,
                params.path,
                msg.value,
                params.minAmountOut,
                params.deadline
            );
        }
        
        // Transfer output to recipient
        IERC20(params.tokenOut).safeTransfer(params.recipient, amountOut);
        
        emit SwapExecuted(msg.sender, WBNB, params.tokenOut, msg.value, amountOut);
    }
    
    /**
     * @notice Execute token to native BNB swap
     */
    function executeSwapToNative(SwapParams calldata params) 
        external 
        override
        nonReentrant
        whenNotPaused
        onlyApprovedRouter(params.router)
        withMEVProtection()
        returns (uint256 amountOut) 
    {
        require(params.deadline >= block.timestamp, "Deadline passed");
        require(params.tokenOut == WBNB, "Output must be WBNB");
        
        // Transfer tokens from sender
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        
        // Approve router
        _ensureApproval(params.tokenIn, params.router, params.amountIn);
        
        // Execute swap to BNB
        amountOut = SwapLib.executeTokenToETHSwap(
            params.router,
            params.tokenIn,
            params.amountIn,
            params.minAmountOut,
            params.deadline
        );
        
        // Send BNB to recipient
        (bool success,) = payable(params.recipient).call{value: amountOut}("");
        require(success, "BNB transfer failed");
        
        emit SwapExecuted(msg.sender, params.tokenIn, WBNB, params.amountIn, amountOut);
    }
    
    /**
     * @notice Execute swap across multiple routers
     */
    function executeMultiRouterSwap(
        address[] calldata routers,
        address[] calldata tokens,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external override nonReentrant whenNotPaused onlyRole(AGGREGATOR_ROLE) returns (uint256 amountOut) {
        require(routers.length == tokens.length - 1, "Invalid route");
        require(deadline >= block.timestamp, "Deadline passed");
        
        // Transfer initial tokens
        IERC20(tokens[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        uint256 currentAmount = amountIn;
        
        // Execute swaps through each router
        for (uint256 i = 0; i < routers.length; i++) {
            require(approvedRouters[routers[i]], "Router not approved");
            
            address tokenIn = tokens[i];
            address tokenOut = tokens[i + 1];
            
            // Approve router
            _ensureApproval(tokenIn, routers[i], currentAmount);
            
            // Execute swap
            currentAmount = SwapLib.executeSwap(
                routers[i],
                tokenIn,
                tokenOut,
                currentAmount,
                i == routers.length - 1 ? minAmountOut : 0, // Only check min on last swap
                deadline
            );
        }
        
        // Transfer final output
        IERC20(tokens[tokens.length - 1]).safeTransfer(recipient, currentAmount);
        
        emit SwapExecuted(
            msg.sender,
            tokens[0],
            tokens[tokens.length - 1],
            amountIn,
            currentAmount
        );
        
        return currentAmount;
    }
    
    
    /**
     * @notice Ensure token approval for router
     */
    function _ensureApproval(address token, address router, uint256 amount) private {
        uint256 currentAllowance = IERC20(token).allowance(address(this), router);
        if (currentAllowance < amount) {
            // Reset approval to 0 first for tokens like USDT
            if (currentAllowance > 0) {
                SafeERC20.forceApprove(IERC20(token), router, 0);
            }
            SafeERC20.forceApprove(IERC20(token), router, type(uint256).max);
        }
    }
    
    
    // --- Admin Functions ---
    
    function approveRouter(address router, bool approved) external onlyRole(AGGREGATOR_ROLE) {
        approvedRouters[router] = approved;
        emit RouterApproved(router, approved);
    }
    
    function setFeeCollector(address _feeCollector) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = _feeCollector;
    }
    
    function setProtocolFee(uint16 _feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feeBps <= 100, "Fee too high");
        protocolFeeBps = _feeBps;
    }
    
    function setV3Handler(address _v3Handler) external onlyRole(DEFAULT_ADMIN_ROLE) {
        v3Handler = _v3Handler;
    }
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    function recoverToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(feeCollector, amount);
    }
    
    function recoverETH() external onlyRole(DEFAULT_ADMIN_ROLE) {
        (bool success,) = payable(feeCollector).call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }
    
    // --- MEV Protection Admin Functions ---
    
    function setMEVProtection(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        mevProtectionEnabled = enabled;
    }
    
    function setTrustedContract(address contract_, bool trusted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        trustedContracts[contract_] = trusted;
    }
    
    receive() external payable {}
}