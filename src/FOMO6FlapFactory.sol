// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {IPortalTypes} from "./flap/IPortal.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {FOMO6FlapVault} from "./FOMO6FlapVault.sol";

/// @notice No owner, proxy, commission or mutable game parameters.
contract FOMO6FlapFactory is VaultFactoryBaseV2 {
    address public immutable postSettlementRecipient;
    mapping(address => address) public vaultForToken;
    event VaultCreated(address indexed token, address indexed vault, address indexed creator);

    constructor(address recipient) {
        require(recipient != address(0), "Zero recipient");
        postSettlementRecipient = recipient;
    }

    function newVault(address predictedToken, address quoteToken, address creator, bytes calldata data)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), "Only VaultPortal");
        require(quoteToken == address(0), "Native BNB only");
        require(data.length == 0, "No configurable parameters");
        require(predictedToken != address(0) && predictedToken.code.length == 0, "Token must be predicted");
        require(vaultForToken[predictedToken] == address(0), "Duplicate token");
        vault = address(new FOMO6FlapVault(predictedToken, postSettlementRecipient));
        vaultForToken[predictedToken] = vault;
        emit VaultCreated(predictedToken, vault, creator);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool) {
        return quoteToken == address(0);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "FOMO6: 20,000-token burn entries, six-hour cap, +30 seconds. Fixed post-settlement recipient. No configurable parameters.";
        schema.fields = new FieldDescriptor[](0);
    }

    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](7);
        policies[0] = FactoryPolicy("quoteToken", "eq", abi.encode(address(0)), "Native BNB only");
        policies[1] = FactoryPolicy("buyTaxRate", "eq", abi.encode(uint16(300)), "3% buy tax");
        policies[2] = FactoryPolicy("sellTaxRate", "eq", abi.encode(uint16(300)), "3% sell tax");
        policies[3] = FactoryPolicy("mktBps", "eq", abi.encode(uint16(10000)), "All market allocation to jackpot");
        policies[4] = FactoryPolicy("deflationBps", "eq", abi.encode(uint16(0)), "No separate deflation allocation");
        policies[5] = FactoryPolicy("dividendBps", "eq", abi.encode(uint16(0)), "No dividend allocation");
        policies[6] = FactoryPolicy("lpBps", "eq", abi.encode(uint16(0)), "No LP allocation");
    }

    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory d)
        internal
        pure
        override
        returns (bool, string memory)
    {
        if (d.tokenVersion != IPortalTypes.TokenVersion.TOKEN_TAXED_V3) {
            return (false, "Tax token V3 required");
        }
        if (d.quoteToken != address(0)) return (false, "Native BNB only");
        if (d.buyTaxRate != 300 || d.sellTaxRate != 300) return (false, "Buy and sell tax must be 3%");
        if (d.vaultBps != 10000 || d.deflationBps != 0 || d.dividendBps != 0 || d.lpBps != 0) {
            return (false, "All market allocation must go to FOMO6");
        }
        return (true, "");
    }
}
