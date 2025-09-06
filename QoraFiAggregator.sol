// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ISwapExecutor.sol";
import "../libraries/SwapUtilities.sol";

// Gas oracle interface for dynamic gas pricing
interface IGasOracle {
    function latestGasPrice() external view returns (uint256);
}

/**
 * @title QoraFiAggregator
 * @notice Handles route finding and optimization, delegates execution to SwapExecutor
 * @dev Reduced size by separating execution logic
 */
contract QoraFiAggregator is AccessControl, Pausable {
    using SafeERC20 for IERC20;
    
    // --- STRUCTS ---
    struct DEXInfo {
        address routerAddress;
        uint8 dexType; // 0=V2, 1=V3, 2=Custom
        bool isActive;
        uint256 priority; // Higher priority = checked first
        uint24 v3Fee; // For V3 routers: fee tier (500 = 0.05%, 3000 = 0.3%, 10000 = 1%)
    }
    
    struct RouteResult {
        address router;
        address[] path;
        uint256 expectedOutput;
        uint256 gasEstimate;
    }
    
    struct AggregatorConfig {
        uint16 maxHops;
        uint256 minTradeSize;
        bool enableMultiHop;
    }
    
    struct AdvancedRouteResult {
        address[] routers;
        address[] tokens;
        uint256 expectedOutput;
        uint256 totalGasEstimate;
        bool isMultiDEX;
    }
    
    // --- STATE ---
    ISwapExecutor public immutable swapExecutor;
    address public immutable WBNB;
    address public immutable USDT;
    
    mapping(bytes32 => DEXInfo) public dexInfo;
    bytes32[] public activeDEXs;
    AggregatorConfig public config;
    
    address[] public commonTokens; // For multi-hop paths
    
    // Gas oracle for dynamic pricing
    IGasOracle public gasOracle;
    uint256 public defaultGasPrice = 5 gwei; // Fallback if oracle fails
    
    // --- EVENTS ---
    event DEXAdded(bytes32 indexed key, address indexed router);
    event DEXRemoved(bytes32 indexed key);
    event RouteFound(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, address router);
    
    constructor(address _swapExecutor, address _wbnb, address _usdt) {
        require(_swapExecutor != address(0), "Invalid executor");
        require(_wbnb != address(0) && _usdt != address(0), "Invalid address");
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        swapExecutor = ISwapExecutor(_swapExecutor);
        WBNB = _wbnb;
        USDT = _usdt;
        
        // Initialize config
        config = AggregatorConfig({
            maxHops: 3,
            minTradeSize: 0.001 ether,
            enableMultiHop: true
        });
        
        // Add common intermediate tokens
        commonTokens.push(_wbnb);
        commonTokens.push(_usdt);
    }
    
    // --- MAIN FUNCTIONS ---
    
    /**
     * @notice Execute optimal swap by finding best route and using SwapExecutor
     */
    function swapOptimal(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external whenNotPaused returns (uint256 amountOut) {
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        // Find best route
        RouteResult memory route = findBestRoute(tokenIn, tokenOut, amountIn);
        require(route.expectedOutput >= minAmountOut, "Insufficient output");
        
        // Transfer tokens to this contract
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Approve executor
        IERC20(tokenIn).approve(address(swapExecutor), amountIn);
        
        // Execute via SwapExecutor
        ISwapExecutor.SwapParams memory params = ISwapExecutor.SwapParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            path: route.path,
            router: route.router,
            recipient: msg.sender,
            deadline: deadline
        });
        
        amountOut = swapExecutor.executeSwap(params);
        
        emit RouteFound(tokenIn, tokenOut, amountIn, route.router);
        
        return amountOut;
    }
    
    /**
     * @notice Swap native BNB optimally
     */
    function swapOptimalNative(
        address tokenOut,
        uint256 minAmountOut,
        uint256 deadline
    ) external payable whenNotPaused returns (uint256 amountOut) {
        require(msg.value >= config.minTradeSize, "Trade too small");
        
        // Find best route from WBNB
        RouteResult memory route = findBestRoute(WBNB, tokenOut, msg.value);
        require(route.expectedOutput >= minAmountOut, "Insufficient output");
        
        // Execute via SwapExecutor
        ISwapExecutor.NativeSwapParams memory params = ISwapExecutor.NativeSwapParams({
            tokenOut: tokenOut,
            minAmountOut: minAmountOut,
            path: route.path,
            router: route.router,
            recipient: msg.sender,
            deadline: deadline
        });
        
        amountOut = swapExecutor.executeNativeSwap{value: msg.value}(params);
        
        emit RouteFound(WBNB, tokenOut, msg.value, route.router);
        
        return amountOut;
    }
    
    /**
     * @notice Get quote for optimal route
     */
    function getQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 expectedOut, address bestRouter, address[] memory bestPath) {
        RouteResult memory route = findBestRoute(tokenIn, tokenOut, amountIn);
        return (route.expectedOutput, route.router, route.path);
    }
    
    /**
     * @notice Enhanced swap function using advanced routing
     */
    function swapAdvanced(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external whenNotPaused returns (uint256 amountOut) {
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        AdvancedRouteResult memory route = findAdvancedRoute(tokenIn, tokenOut, amountIn);
        require(route.expectedOutput >= minAmountOut, "Insufficient output");
        
        if (route.isMultiDEX) {
            // Use multi-DEX execution
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).approve(address(swapExecutor), amountIn);
            
            amountOut = swapExecutor.executeMultiRouterSwap(
                route.routers,
                route.tokens,
                amountIn,
                minAmountOut,
                msg.sender,
                deadline
            );
        } else {
            // Use existing single DEX execution
            amountOut = swapOptimal(tokenIn, tokenOut, amountIn, minAmountOut, deadline);
        }
    }
    
    /**
     * @notice Find best route including multi-DEX options
     */
    function findAdvancedRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (AdvancedRouteResult memory bestRoute) {
        
        // Check single DEX routes first
        RouteResult memory singleRoute = findBestRoute(tokenIn, tokenOut, amountIn);
        
        bestRoute.routers = new address[](1);
        bestRoute.routers[0] = singleRoute.router;
        bestRoute.tokens = singleRoute.path;
        bestRoute.expectedOutput = singleRoute.expectedOutput;
        bestRoute.totalGasEstimate = singleRoute.gasEstimate;
        bestRoute.isMultiDEX = false;
        
        // Check multi-DEX routes if enabled
        if (config.enableMultiHop) {
            AdvancedRouteResult memory multiRoute = findBestMultiDEXRoute(tokenIn, tokenOut, amountIn);
            
            // Compare considering gas costs
            uint256 singleNetOutput = _adjustForGasCosts(bestRoute.expectedOutput, bestRoute.totalGasEstimate);
            uint256 multiNetOutput = _adjustForGasCosts(multiRoute.expectedOutput, multiRoute.totalGasEstimate);
            
            if (multiNetOutput > singleNetOutput) {
                bestRoute = multiRoute;
            }
        }
    }
    
    /**
     * @notice Find best multi-DEX route
     */
    function findBestMultiDEXRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (AdvancedRouteResult memory bestRoute) {
        // Initialize with empty route
        bestRoute.expectedOutput = 0;
        
        // Try routes through common intermediate tokens
        for (uint256 i = 0; i < commonTokens.length; i++) {
            address intermediate = commonTokens[i];
            
            // Skip if intermediate is input or output
            if (intermediate == tokenIn || intermediate == tokenOut) continue;
            
            // Find best DEX for first hop
            (address router1, uint256 intermediateAmount) = findBestDEXForPair(
                tokenIn,
                intermediate,
                amountIn
            );
            
            if (intermediateAmount == 0) continue;
            
            // Find best DEX for second hop (can be different from first)
            (address router2, uint256 finalAmount) = findBestDEXForPair(
                intermediate,
                tokenOut,
                intermediateAmount
            );
            
            if (finalAmount > bestRoute.expectedOutput) {
                bestRoute.expectedOutput = finalAmount;
                bestRoute.routers = new address[](2);
                bestRoute.routers[0] = router1;
                bestRoute.routers[1] = router2;
                bestRoute.tokens = new address[](3);
                bestRoute.tokens[0] = tokenIn;
                bestRoute.tokens[1] = intermediate;
                bestRoute.tokens[2] = tokenOut;
                bestRoute.totalGasEstimate = 300000; // Estimated gas for multi-DEX
                bestRoute.isMultiDEX = true;
            }
        }
        
        return bestRoute;
    }
    
    /**
     * @notice Adjust output for gas costs
     */
    function _adjustForGasCosts(uint256 output, uint256 gasEstimate) internal view returns (uint256) {
        uint256 currentGasPrice = _getCurrentGasPrice();
        uint256 gasCostInWei = gasEstimate * currentGasPrice;
        
        // Convert gas cost to token terms (simplified - in production would use price feed)
        // Assuming 1 BNB = 1000 tokens for estimation (should use actual price oracle)
        uint256 gasCostInTokens = (gasCostInWei * 1000) / 1e18;
        
        if (output > gasCostInTokens) {
            return output - gasCostInTokens;
        }
        return 0;
    }
    
    /**
     * @notice Get current gas price from oracle or use default
     */
    function _getCurrentGasPrice() internal view returns (uint256) {
        if (address(gasOracle) != address(0)) {
            try gasOracle.latestGasPrice() returns (uint256 price) {
                if (price > 0) return price;
            } catch {
                // Oracle failed, use default
            }
        }
        return defaultGasPrice;
    }
    
    // --- ROUTE FINDING ---
    
    /**
     * @notice Find best route across all DEXs
     */
    function findBestRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) public view returns (RouteResult memory bestRoute) {
        require(activeDEXs.length > 0, "No active DEXs");
        
        uint256 bestOutput = 0;
        
        // Check direct routes
        for (uint256 i = 0; i < activeDEXs.length; i++) {
            DEXInfo memory dex = dexInfo[activeDEXs[i]];
            if (!dex.isActive) continue;
            
            uint256 output = SwapLib.getExpectedSwapOutput(
                dex.routerAddress,
                tokenIn,
                tokenOut,
                amountIn
            );
            
            if (output > bestOutput) {
                bestOutput = output;
                bestRoute.router = dex.routerAddress;
                bestRoute.path = _createPath(tokenIn, tokenOut);
                bestRoute.expectedOutput = output;
                bestRoute.gasEstimate = 150000; // Estimated gas for direct swap
            }
        }
        
        // Check multi-hop routes if enabled
        if (config.enableMultiHop) {
            RouteResult memory multiHopRoute = findBestMultiHopRoute(tokenIn, tokenOut, amountIn);
            if (multiHopRoute.expectedOutput > bestOutput) {
                bestRoute = multiHopRoute;
            }
        }
        
        require(bestRoute.expectedOutput > 0, "No route found");
    }
    
    /**
     * @notice Find best multi-hop route
     */
    function findBestMultiHopRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (RouteResult memory bestRoute) {
        uint256 bestOutput = 0;
        
        // Try routes through common intermediate tokens
        for (uint256 i = 0; i < commonTokens.length; i++) {
            address intermediate = commonTokens[i];
            
            // Skip if intermediate is input or output
            if (intermediate == tokenIn || intermediate == tokenOut) continue;
            
            // Find best DEX for first hop
            (address router1, uint256 intermediateAmount) = findBestDEXForPair(
                tokenIn,
                intermediate,
                amountIn
            );
            
            if (intermediateAmount == 0) continue;
            
            // Find best DEX for second hop
            (address router2, uint256 finalAmount) = findBestDEXForPair(
                intermediate,
                tokenOut,
                intermediateAmount
            );
            
            if (finalAmount > bestOutput) {
                bestOutput = finalAmount;
                
                // Use same router if possible for gas efficiency
                bestRoute.router = (router1 == router2) ? router1 : router1;
                bestRoute.path = _createMultiHopPath(tokenIn, intermediate, tokenOut);
                bestRoute.expectedOutput = finalAmount;
                bestRoute.gasEstimate = 250000; // Estimated gas for multi-hop
            }
        }
    }
    
    /**
     * @notice Find best DEX for a specific pair
     */
    function findBestDEXForPair(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (address bestRouter, uint256 bestOutput) {
        for (uint256 i = 0; i < activeDEXs.length; i++) {
            DEXInfo memory dex = dexInfo[activeDEXs[i]];
            if (!dex.isActive) continue;
            
            uint256 output = SwapLib.getExpectedSwapOutput(
                dex.routerAddress,
                tokenIn,
                tokenOut,
                amountIn
            );
            
            if (output > bestOutput) {
                bestOutput = output;
                bestRouter = dex.routerAddress;
            }
        }
    }
    
    // --- ADMIN FUNCTIONS ---
    
    function addDEX(
        bytes32 key,
        address routerAddress,
        uint8 dexType,
        uint256 priority
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        addDEXWithV3Fee(key, routerAddress, dexType, priority, 0);
    }
    
    function addDEXWithV3Fee(
        bytes32 key,
        address routerAddress,
        uint8 dexType,
        uint256 priority,
        uint24 v3Fee
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(routerAddress != address(0), "Invalid router");
        require(dexInfo[key].routerAddress == address(0), "DEX exists");
        
        dexInfo[key] = DEXInfo({
            routerAddress: routerAddress,
            dexType: dexType,
            isActive: true,
            priority: priority,
            v3Fee: v3Fee
        });
        
        activeDEXs.push(key);
        
        // Note: SwapExecutor admin must grant AGGREGATOR_ROLE to this contract
        // to allow router approval management
        
        emit DEXAdded(key, routerAddress);
    }
    
    function removeDEX(bytes32 key) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(dexInfo[key].routerAddress != address(0), "DEX not found");
        
        // Remove from array
        for (uint256 i = 0; i < activeDEXs.length; i++) {
            if (activeDEXs[i] == key) {
                activeDEXs[i] = activeDEXs[activeDEXs.length - 1];
                activeDEXs.pop();
                break;
            }
        }
        
        // Note: SwapExecutor admin should revoke router approval if needed
        
        delete dexInfo[key];
        emit DEXRemoved(key);
    }
    
    function updateConfig(
        uint16 _maxHops,
        uint256 _minTradeSize,
        bool _enableMultiHop
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        config.maxHops = _maxHops;
        config.minTradeSize = _minTradeSize;
        config.enableMultiHop = _enableMultiHop;
    }
    
    function addCommonToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token");
        commonTokens.push(token);
    }
    
    function setGasOracle(address _gasOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        gasOracle = IGasOracle(_gasOracle);
    }
    
    function setDefaultGasPrice(uint256 _defaultGasPrice) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_defaultGasPrice >= 1 gwei && _defaultGasPrice <= 100 gwei, "Invalid gas price");
        defaultGasPrice = _defaultGasPrice;
    }
    
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    // --- HELPER FUNCTIONS ---
    
    function _createPath(address tokenIn, address tokenOut) private pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return path;
    }
    
    function _createMultiHopPath(
        address tokenIn,
        address intermediate,
        address tokenOut
    ) private pure returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = intermediate;
        path[2] = tokenOut;
        return path;
    }
    
    // --- VIEW FUNCTIONS ---
    
    function getDEXCount() external view returns (uint256) {
        return activeDEXs.length;
    }
    
    function getAllDEXs() external view returns (bytes32[] memory) {
        return activeDEXs;
    }
    
    function getCommonTokens() external view returns (address[] memory) {
        return commonTokens;
    }
    
    function version() external pure returns (string memory) {
        return "QoraFiAggregator-1.0.0";
    }
}