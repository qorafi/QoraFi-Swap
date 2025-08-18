// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Use existing libraries  
import "../libraries/SwapUtilities.sol";

// V3 Handler Interface
interface IQoraFiV3Handler {
    struct V3Quote {
        uint256 amountOut;
        uint24 fee;
        uint256 gasEstimate;
        bool isValid;
    }
    
    function getBestV3Quote(address tokenIn, address tokenOut, uint256 amountIn) external returns (V3Quote memory);
    function executeV3Swap(bytes32 dexKey, address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 amountOutMinimum, address recipient, uint256 deadline) external returns (uint256);
    function getV3DEXCount() external view returns (uint256);
}

/**
 * @title QoraFiAggregator
 * @notice Advanced DEX aggregator with multi-hop optimization and V2/V3 support
 * @dev Separate contract for advanced features to keep main router lightweight
 */
contract QoraFiAggregator is AccessControl, ReentrancyGuard, Pausable {
    
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant AGGREGATOR_MANAGER_ROLE = keccak256("AGGREGATOR_MANAGER_ROLE");

    // --- STRUCTS ---
    struct DEXInfo {
        address routerAddress;
        uint8 dexType; // 0=V2, 2=Custom (V3 handled by separate contract)
        bool isActive;
        uint256 successfulTrades;
        uint256 totalVolume;
    }

    struct TradeRoute {
        bytes32[] dexKeys;
        address[] tokens;
        uint24[] fees; // For V3 pools
        uint256 expectedOutput;
        uint256 gasEstimate;
    }

    struct AggregatorConfig {
        uint16 maxHops;
        uint16 maxRoutes;
        uint256 minTradeSize;
        uint256 maxSlippage;
        bool enableMultiHop;
        bool enableGasOptimization;
    }

    // --- STATE VARIABLES ---
    mapping(bytes32 => DEXInfo) public dexInfo;
    bytes32[] public activeDEXs;
    
    AggregatorConfig public config;
    address public feeCollector;
    uint16 public aggregatorFeeBps; // Separate fee for aggregation service
    
    // V3 Handler contract
    IQoraFiV3Handler public v3Handler;
    
    
    // Popular token addresses for path optimization
    address public immutable WBNB;
    address public immutable USDT;
    address public immutable BUSD;
    address[] public commonTokens;

    // --- EVENTS ---
    event DEXAdded(bytes32 indexed key, address indexed router, uint8 dexType);
    event DEXRemoved(bytes32 indexed key);
    event OptimalRouteFound(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 expectedOut);
    event MultiHopTradeExecuted(address indexed user, address[] path, uint256 amountIn, uint256 amountOut);
    event ConfigUpdated(uint16 maxHops, uint16 maxRoutes, bool enableMultiHop);

    // --- ERRORS ---
    error InvalidDEX();
    error RouteNotFound();
    error ExcessiveSlippage();
    error TradeAboveLimit();

    constructor(
        address _wbnb,
        address _usdt, 
        address _busd,
        address _feeCollector,
        address _v3Handler
    ) {
        require(_wbnb != address(0) && _feeCollector != address(0), "Invalid address");
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(AGGREGATOR_MANAGER_ROLE, msg.sender);

        WBNB = _wbnb;
        USDT = _usdt;
        BUSD = _busd;
        feeCollector = _feeCollector;
        v3Handler = IQoraFiV3Handler(_v3Handler);
        
        // Initialize config
        config = AggregatorConfig({
            maxHops: 4,
            maxRoutes: 10,
            minTradeSize: 0.001 ether,
            maxSlippage: 500, // 5%
            enableMultiHop: true,
            enableGasOptimization: true
        });
        
        aggregatorFeeBps = 10; // 0.1% aggregation fee
        
        
        // Set common tokens for path finding
        commonTokens.push(_wbnb);
        commonTokens.push(_usdt);
        commonTokens.push(_busd);
    }

    // --- AGGREGATION FUNCTIONS ---

    /**
     * @notice Find optimal route across multiple DEXs with multi-hop support
     */
    function findOptimalRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (TradeRoute memory bestRoute) {
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        TradeRoute[] memory routes = new TradeRoute[](config.maxRoutes);
        uint256 routeCount = 0;
        
        // Generate direct routes (single hop)
        routeCount = _generateDirectRoutes(tokenIn, tokenOut, amountIn, routes, routeCount);
        
        // Generate multi-hop routes if enabled
        if (config.enableMultiHop && routeCount < config.maxRoutes) {
            routeCount = _generateMultiHopRoutes(tokenIn, tokenOut, amountIn, routes, routeCount);
        }
        
        // Note: V3 quotes are handled separately in execution functions
        // since quoter functions are not view functions
        
        // Select best route considering output and gas cost
        bestRoute = _selectBestRoute(routes, routeCount, amountIn);
        
        if (bestRoute.expectedOutput == 0) revert RouteNotFound();
    }

    /**
     * @notice Execute optimal multi-hop trade
     */
    function executeOptimalTrade(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address to,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "Deadline exceeded");
        
        // Basic size validation
        require(amountIn >= config.minTradeSize, "Trade too small");
        
        // Find optimal route
        TradeRoute memory route = this.findOptimalRoute(tokenIn, tokenOut, amountIn);
        
        emit OptimalRouteFound(tokenIn, tokenOut, amountIn, route.expectedOutput);
        
        // Verify slippage
        uint256 expectedAfterFee = (route.expectedOutput * (10000 - aggregatorFeeBps)) / 10000;
        if (expectedAfterFee < minAmountOut) revert ExcessiveSlippage();
        
        // Transfer input tokens
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        
        // Calculate and collect aggregator fee
        uint256 feeAmount = (amountIn * aggregatorFeeBps) / 10000;
        uint256 tradeAmount = amountIn - feeAmount;
        
        if (feeAmount > 0) {
            IERC20(tokenIn).transfer(feeCollector, feeAmount);
        }
        
        // Execute multi-hop trade
        uint256 finalOutput = _executeMultiHopTrade(route, tradeAmount, deadline);
        
        // Verify minimum output
        require(finalOutput >= minAmountOut, "Insufficient output");
        
        // Transfer output tokens to recipient
        IERC20(tokenOut).transfer(to, finalOutput);
        
        
        emit MultiHopTradeExecuted(msg.sender, route.tokens, tradeAmount, finalOutput);
    }

    /**
     * @notice Get quote with multi-hop optimization
     */
    function getOptimalQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut, uint256 gasEstimate) {
        TradeRoute memory route = this.findOptimalRoute(tokenIn, tokenOut, amountIn);
        
        // Apply aggregator fee to quote
        amountOut = (route.expectedOutput * (10000 - aggregatorFeeBps)) / 10000;
        gasEstimate = route.gasEstimate;
    }

    /**
     * @notice Get optimal quote including V3 (non-view due to V3 quoter limitations)
     */
    function getOptimalQuoteWithV3(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut, uint256 gasEstimate, bool isV3) {
        // Get V2 quote first
        TradeRoute memory v2Route = this.findOptimalRoute(tokenIn, tokenOut, amountIn);
        uint256 v2AmountOut = (v2Route.expectedOutput * (10000 - aggregatorFeeBps)) / 10000;
        
        uint256 bestAmountOut = v2AmountOut;
        uint256 bestGasEstimate = v2Route.gasEstimate;
        bool useV3 = false;
        
        // Try V3 if handler is available
        if (address(v3Handler) != address(0)) {
            try v3Handler.getBestV3Quote(tokenIn, tokenOut, amountIn) returns (IQoraFiV3Handler.V3Quote memory v3Quote) {
                if (v3Quote.isValid && v3Quote.amountOut > 0) {
                    uint256 v3AmountOutAfterFee = (v3Quote.amountOut * (10000 - aggregatorFeeBps)) / 10000;
                    if (v3AmountOutAfterFee > bestAmountOut) {
                        bestAmountOut = v3AmountOutAfterFee;
                        bestGasEstimate = v3Quote.gasEstimate;
                        useV3 = true;
                    }
                }
            } catch {
                // V3 failed, use V2
            }
        }
        
        return (bestAmountOut, bestGasEstimate, useV3);
    }

    // --- INTERNAL FUNCTIONS ---

    function _generateDirectRoutes(
        address tokenIn,
        address tokenOut, 
        uint256 amountIn,
        TradeRoute[] memory routes,
        uint256 routeCount
    ) internal view returns (uint256) {
        uint256 dexCount = activeDEXs.length;
        
        for (uint256 i = 0; i < dexCount && routeCount < config.maxRoutes; i++) {
            bytes32 dexKey = activeDEXs[i];
            DEXInfo storage dex = dexInfo[dexKey];
            
            if (!dex.isActive) continue;
            
            // Only handle V2 DEXs here - V3 handled by separate contract
            if (dex.dexType == 0) { // V2
                uint256 expectedOut = SwapLib.getExpectedSwapOutput(
                    dex.routerAddress,
                    tokenIn,
                    tokenOut,
                    amountIn
                );
                
                if (expectedOut > 0) {
                    routes[routeCount] = TradeRoute({
                        dexKeys: _createSingleDEXArray(dexKey),
                        tokens: _createTokenPath(tokenIn, tokenOut),
                        fees: new uint24[](0),
                        expectedOutput: expectedOut,
                        gasEstimate: _estimateGasCost(1)
                    });
                    routeCount++;
                }
            }
        }
        
        return routeCount;
    }

    function _generateMultiHopRoutes(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        TradeRoute[] memory routes,
        uint256 routeCount
    ) internal view returns (uint256) {
        // Generate routes through common tokens (WBNB, USDT, BUSD)
        for (uint256 i = 0; i < commonTokens.length && routeCount < config.maxRoutes; i++) {
            address intermediateToken = commonTokens[i];
            
            if (intermediateToken == tokenIn || intermediateToken == tokenOut) continue;
            
            // Try tokenIn -> intermediate -> tokenOut
            uint256 bestOutput = _calculateMultiHopOutput(tokenIn, intermediateToken, tokenOut, amountIn);
            
            if (bestOutput > 0) {
                routes[routeCount] = TradeRoute({
                    dexKeys: new bytes32[](0), // Simplified for now
                    tokens: _createMultiHopPath(tokenIn, intermediateToken, tokenOut),
                    fees: new uint24[](0),
                    expectedOutput: bestOutput,
                    gasEstimate: _estimateGasCost(2) // Two hops
                });
                routeCount++;
            }
        }
        
        return routeCount;
    }

    function _calculateMultiHopOutput(
        address tokenIn,
        address intermediate,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256) {
        // Find best DEX for first hop
        uint256 bestFirstHop = 0;
        uint256 dexCount = activeDEXs.length;
        
        for (uint256 i = 0; i < dexCount; i++) {
            bytes32 dexKey = activeDEXs[i];
            DEXInfo storage dex = dexInfo[dexKey];
            
            if (!dex.isActive) continue;
            
            uint256 intermediateAmount = SwapLib.getExpectedSwapOutput(
                dex.routerAddress,
                tokenIn,
                intermediate,
                amountIn
            );
            
            if (intermediateAmount > bestFirstHop) {
                bestFirstHop = intermediateAmount;
            }
        }
        
        if (bestFirstHop == 0) return 0;
        
        // Find best DEX for second hop
        uint256 bestSecondHop = 0;
        
        for (uint256 i = 0; i < dexCount; i++) {
            bytes32 dexKey = activeDEXs[i];
            DEXInfo storage dex = dexInfo[dexKey];
            
            if (!dex.isActive) continue;
            
            uint256 finalAmount = SwapLib.getExpectedSwapOutput(
                dex.routerAddress,
                intermediate,
                tokenOut,
                bestFirstHop
            );
            
            if (finalAmount > bestSecondHop) {
                bestSecondHop = finalAmount;
            }
        }
        
        return bestSecondHop;
    }

    function _selectBestRoute(
        TradeRoute[] memory routes,
        uint256 routeCount,
        uint256 amountIn
    ) internal view returns (TradeRoute memory bestRoute) {
        uint256 bestScore = 0;
        
        for (uint256 i = 0; i < routeCount; i++) {
            uint256 score = routes[i].expectedOutput;
            
            // Apply gas cost penalty if gas optimization is enabled
            if (config.enableGasOptimization) {
                uint256 gasCostInTokens = _convertGasCostToTokens(routes[i].gasEstimate, amountIn);
                if (score > gasCostInTokens) {
                    score -= gasCostInTokens;
                }
            }
            
            if (score > bestScore) {
                bestScore = score;
                bestRoute = routes[i];
            }
        }
    }

    function _executeMultiHopTrade(
        TradeRoute memory route,
        uint256 amountIn,
        uint256 deadline
    ) internal returns (uint256 finalAmount) {
        // Simplified implementation for multi-hop execution
        // In a full implementation, this would iterate through the route
        // and execute each hop using the appropriate DEX
        
        uint256 currentAmount = amountIn;
        address currentToken = route.tokens[0];
        
        for (uint256 i = 1; i < route.tokens.length; i++) {
            address nextToken = route.tokens[i];
            
            // Find best DEX for this hop (simplified)
            bytes32 bestDEX = activeDEXs[0]; // Use first DEX for now
            address router = dexInfo[bestDEX].routerAddress;
            
            // Execute swap using SwapLib
            currentAmount = SwapLib.executeSwap(
                router,
                currentToken,
                nextToken,
                currentAmount,
                0, // We'll handle slippage at the final step
                deadline
            );
            
            currentToken = nextToken;
            
            // Update DEX statistics
            dexInfo[bestDEX].successfulTrades++;
            dexInfo[bestDEX].totalVolume += currentAmount;
        }
        
        return currentAmount;
    }

    // --- HELPER FUNCTIONS ---

    function _createSingleDEXArray(bytes32 dexKey) internal pure returns (bytes32[] memory) {
        bytes32[] memory result = new bytes32[](1);
        result[0] = dexKey;
        return result;
    }

    function _createTokenPath(address tokenIn, address tokenOut) internal pure returns (address[] memory) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        return path;
    }

    function _createMultiHopPath(address tokenIn, address intermediate, address tokenOut) internal pure returns (address[] memory) {
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = intermediate;
        path[2] = tokenOut;
        return path;
    }

    function _estimateGasCost(uint256 hops) internal pure returns (uint256) {
        // Rough gas estimate based on number of hops
        return 100000 + (hops * 50000); // Base + hop cost
    }

    function _convertGasCostToTokens(uint256 gasEstimate, uint256 amountIn) internal pure returns (uint256) {
        // Convert gas cost to token equivalent (simplified)
        // In reality, this would use gas price and token price oracles
        return (gasEstimate * amountIn) / 1000000; // Rough approximation
    }

    /**
     * @notice Update V3Handler address
     */
    function setV3Handler(address _v3Handler) external onlyRole(GOVERNANCE_ROLE) {
        require(_v3Handler != address(0), "Invalid V3Handler");
        v3Handler = IQoraFiV3Handler(_v3Handler);
    }

    // --- ADMIN FUNCTIONS ---

    function addDEX(
        bytes32 key,
        address routerAddress,
        uint8 dexType
    ) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        require(routerAddress != address(0), "Invalid router");
        require(dexType == 0 || dexType == 2, "Use V3Handler for V3 DEXs"); // Only V2 or Custom
        if (dexInfo[key].routerAddress != address(0)) revert InvalidDEX();
        
        dexInfo[key] = DEXInfo({
            routerAddress: routerAddress,
            dexType: dexType,
            isActive: true,
            successfulTrades: 0,
            totalVolume: 0
        });
        
        activeDEXs.push(key);
        emit DEXAdded(key, routerAddress, dexType);
    }

    function removeDEX(bytes32 key) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        if (dexInfo[key].routerAddress == address(0)) revert InvalidDEX();
        
        // Remove from activeDEXs array
        uint256 length = activeDEXs.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeDEXs[i] == key) {
                activeDEXs[i] = activeDEXs[length - 1];
                activeDEXs.pop();
                break;
            }
        }
        
        delete dexInfo[key];
        emit DEXRemoved(key);
    }

    function updateConfig(
        uint16 maxHops,
        uint16 maxRoutes,
        uint256 minTradeSize,
        uint256 maxSlippage,
        bool enableMultiHop,
        bool enableGasOptimization
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(maxHops <= 10 && maxRoutes <= 50, "Invalid limits");
        
        config.maxHops = maxHops;
        config.maxRoutes = maxRoutes;
        config.minTradeSize = minTradeSize;
        config.maxSlippage = maxSlippage;
        config.enableMultiHop = enableMultiHop;
        config.enableGasOptimization = enableGasOptimization;
        
        emit ConfigUpdated(maxHops, maxRoutes, enableMultiHop);
    }

    function setAggregatorFee(uint16 newFeeBps) external onlyRole(GOVERNANCE_ROLE) {
        require(newFeeBps <= 100, "Fee too high"); // Max 1%
        aggregatorFeeBps = newFeeBps;
    }

    function addCommonToken(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token");
        commonTokens.push(token);
    }

    // --- VIEW FUNCTIONS ---

    function getDEXCount() external view returns (uint256) {
        return activeDEXs.length;
    }

    /**
     * @notice Remove token from common tokens list
     */
    function removeCommonToken(uint256 index) external onlyRole(GOVERNANCE_ROLE) {
        require(index < commonTokens.length, "Invalid index");
        commonTokens[index] = commonTokens[commonTokens.length - 1];
        commonTokens.pop();
    }

    /**
     * @notice Get list of common tokens
     */
    function getCommonTokens() external view returns (address[] memory) {
        return commonTokens;
    }

    /**
     * @notice Update DEX status (enable/disable)
     */
    function updateDEXStatus(bytes32 key, bool isActive) external onlyRole(AGGREGATOR_MANAGER_ROLE) {
        require(dexInfo[key].routerAddress != address(0), "DEX does not exist");
        dexInfo[key].isActive = isActive;
    }

    /**
     * @notice Get detailed DEX information
     */
    function getDEXInfo(bytes32 key) external view returns (
        address routerAddress,
        uint8 dexType,
        bool isActive,
        uint256 successfulTrades,
        uint256 totalVolume
    ) {
        DEXInfo storage dex = dexInfo[key];
        return (dex.routerAddress, dex.dexType, dex.isActive, dex.successfulTrades, dex.totalVolume);
    }

    /**
     * @notice Get all DEXs with performance data
     */
    function getAllDEXs() external view returns (
        bytes32[] memory keys,
        address[] memory addresses,
        uint8[] memory dexTypes,
        bool[] memory statuses,
        uint256[] memory successCounts,
        uint256[] memory volumes
    ) {
        uint256 length = activeDEXs.length;
        keys = new bytes32[](length);
        addresses = new address[](length);
        dexTypes = new uint8[](length);
        statuses = new bool[](length);
        successCounts = new uint256[](length);
        volumes = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            bytes32 key = activeDEXs[i];
            DEXInfo storage dex = dexInfo[key];
            keys[i] = key;
            addresses[i] = dex.routerAddress;
            dexTypes[i] = dex.dexType;
            statuses[i] = dex.isActive;
            successCounts[i] = dex.successfulTrades;
            volumes[i] = dex.totalVolume;
        }
    }




    /**
     * @notice Emergency pause function
     */
    function emergencyPause() external onlyRole(GOVERNANCE_ROLE) {
        _pause();
    }

    /**
     * @notice Emergency unpause function
     */
    function emergencyUnpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    /**
     * @notice Get aggregator performance metrics
     */
    function getPerformanceMetrics() external view returns (
        uint256 totalDEXs,
        uint256 activeDEXCount,
        uint256 totalTrades,
        uint256 totalVolume,
        uint16 currentFee
    ) {
        totalDEXs = activeDEXs.length;
        
        for (uint256 i = 0; i < activeDEXs.length; i++) {
            DEXInfo storage dex = dexInfo[activeDEXs[i]];
            if (dex.isActive) activeDEXCount++;
            totalTrades += dex.successfulTrades;
            totalVolume += dex.totalVolume;
        }
        
        currentFee = aggregatorFeeBps;
    }

    /**
     * @notice Recover accidentally sent tokens
     */
    function recoverERC20(address token, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        IERC20(token).transfer(feeCollector, amount);
    }

    /**
     * @notice Get contract version
     */
    function version() external pure returns (string memory) {
        return "QoraFiAggregator-v1.0.0";
    }

    /**
     * @notice Get current configuration
     */
    function getConfig() external view returns (
        uint16 maxHops,
        uint16 maxRoutes,
        uint256 minTradeSize,
        uint256 maxSlippage,
        bool enableMultiHop,
        bool enableGasOptimization
    ) {
        return (
            config.maxHops,
            config.maxRoutes,
            config.minTradeSize,
            config.maxSlippage,
            config.enableMultiHop,
            config.enableGasOptimization
        );
    }

}