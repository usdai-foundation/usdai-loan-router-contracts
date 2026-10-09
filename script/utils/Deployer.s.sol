// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import {stdJson} from "forge-std/StdJson.sol";
import {console2 as console} from "forge-std/console2.sol";

import {BaseScript} from "./Base.s.sol";

contract Deployer is BaseScript {
    /*--------------------------------------------------------------------------*/
    /* Errors                                                                   */
    /*--------------------------------------------------------------------------*/

    error MissingDependency();

    error AlreadyDeployed();

    error InvalidParameter();

    /*--------------------------------------------------------------------------*/
    /* Structures                                                               */
    /*--------------------------------------------------------------------------*/

    struct Deployment {
        address loanRouterV2;
        address loanScheduleViewer;
        address depositTimelock;
        address escrowTimelock;
        address collateralTimelock;
        address simpleInterestRateModel;
        address amortizedInterestRateModel;
        address absoluteFeeModel;
        address ratioFeeModel;
        address proratedRatioFeeModel;
        address reserveAccountBeacon;
        address reserveAccountFactory;
    }

    /*--------------------------------------------------------------------------*/
    /* State Variables                                                          */
    /*--------------------------------------------------------------------------*/

    Deployment internal _deployment;

    /*--------------------------------------------------------------------------*/
    /* Modifier                                                                 */
    /*--------------------------------------------------------------------------*/

    /**
     * @dev Add useDeployment modifier to deployment script run() function to
     *      deserialize deployments json and make properties available to read,
     *      write and modify. Changes are re-serialized at end of script.
     */
    modifier useDeployment() {
        console.log("Using deployment\n");
        console.log("Network: %s\n", _chainIdToNetwork[block.chainid]);

        _deserialize();

        _;

        _serialize();

        console.log("Using deployment completed\n");
    }

    /*--------------------------------------------------------------------------*/
    /* Internal Helpers                                                         */
    /*--------------------------------------------------------------------------*/

    /**
     * @notice Internal helper to get deployment file path for current network
     *
     * @return Path
     */
    function _getJsonFilePath() internal view returns (string memory) {
        return string(abi.encodePacked(vm.projectRoot(), "/deployments/", _chainIdToNetwork[block.chainid], ".json"));
    }

    /**
     * @notice Internal helper to read and return json string
     *
     * @return Json string
     */
    function _getJson() internal view returns (string memory) {
        string memory path = _getJsonFilePath();

        string memory json = "{}";

        /// forge-lint: disable-next-line(unsafe-cheatcode)
        try vm.readFile(path) returns (string memory _json) {
            json = _json;
        } catch {
            console.log("No json file found at: %s\n", path);
        }

        return json;
    }

    /*--------------------------------------------------------------------------*/
    /* API                                                                      */
    /*--------------------------------------------------------------------------*/

    /**
     * @notice Serialize the _deployment storage struct
     */
    function _serialize() internal {
        /* Initialize json string */
        string memory json = "";

        json = stdJson.serialize("", "loanRouterV2", _deployment.loanRouterV2);
        json = stdJson.serialize("", "loanScheduleViewer", _deployment.loanScheduleViewer);
        json = stdJson.serialize("", "depositTimelock", _deployment.depositTimelock);
        json = stdJson.serialize("", "escrowTimelock", _deployment.escrowTimelock);
        json = stdJson.serialize("", "collateralTimelock", _deployment.collateralTimelock);
        json = stdJson.serialize("", "simpleInterestRateModel", _deployment.simpleInterestRateModel);
        json = stdJson.serialize("", "amortizedInterestRateModel", _deployment.amortizedInterestRateModel);
        json = stdJson.serialize("", "absoluteFeeModel", _deployment.absoluteFeeModel);
        json = stdJson.serialize("", "ratioFeeModel", _deployment.ratioFeeModel);
        json = stdJson.serialize("", "proratedRatioFeeModel", _deployment.proratedRatioFeeModel);
        json = stdJson.serialize("", "reserveAccountBeacon", _deployment.reserveAccountBeacon);
        json = stdJson.serialize("", "reserveAccountFactory", _deployment.reserveAccountFactory);

        console.log("Writing json to file: %s\n", json);
        vm.writeJson(json, _getJsonFilePath());
    }

    /**
     * @notice Deserialize the deployment json
     *
     * @dev Deserialization loads the json into the _deployment struct
     */
    function _deserialize() internal {
        string memory json = _getJson();

        /* Deserialize loanRouterV2 */
        try vm.parseJsonAddress(json, ".loanRouterV2") returns (address instance) {
            _deployment.loanRouterV2 = instance;
        } catch {
            console.log("Could not parse loanRouterV2");
        }

        /* Deserialize loanScheduleViewer */
        try vm.parseJsonAddress(json, ".loanScheduleViewer") returns (address instance) {
            _deployment.loanScheduleViewer = instance;
        } catch {
            console.log("Could not parse loanScheduleViewer");
        }

        /* Deserialize depositTimelock */
        try vm.parseJsonAddress(json, ".depositTimelock") returns (address instance) {
            _deployment.depositTimelock = instance;
        } catch {
            console.log("Could not parse depositTimelock");
        }

        /* Deserialize escrowTimelock */
        try vm.parseJsonAddress(json, ".escrowTimelock") returns (address instance) {
            _deployment.escrowTimelock = instance;
        } catch {
            console.log("Could not parse escrowTimelock");
        }

        /* Deserialize collateralTimelock */
        try vm.parseJsonAddress(json, ".collateralTimelock") returns (address instance) {
            _deployment.collateralTimelock = instance;
        } catch {
            console.log("Could not parse collateralTimelock");
        }

        /* Deserialize simpleInterestRateModel */
        try vm.parseJsonAddress(json, ".simpleInterestRateModel") returns (address instance) {
            _deployment.simpleInterestRateModel = instance;
        } catch {
            console.log("Could not parse simpleInterestRateModel");
        }

        /* Deserialize amortizedInterestRateModel */
        try vm.parseJsonAddress(json, ".amortizedInterestRateModel") returns (address instance) {
            _deployment.amortizedInterestRateModel = instance;
        } catch {
            console.log("Could not parse amortizedInterestRateModel");
        }

        /* Deserialize absoluteFeeModel */
        try vm.parseJsonAddress(json, ".absoluteFeeModel") returns (address instance) {
            _deployment.absoluteFeeModel = instance;
        } catch {
            console.log("Could not parse absoluteFeeModel");
        }

        /* Deserialize ratioFeeModel */
        try vm.parseJsonAddress(json, ".ratioFeeModel") returns (address instance) {
            _deployment.ratioFeeModel = instance;
        } catch {
            console.log("Could not parse ratioFeeModel");
        }

        /* Deserialize proratedRatioFeeModel */
        try vm.parseJsonAddress(json, ".proratedRatioFeeModel") returns (address instance) {
            _deployment.proratedRatioFeeModel = instance;
        } catch {
            console.log("Could not parse proratedRatioFeeModel");
        }

        /* Deserialize reserveAccountBeacon */
        try vm.parseJsonAddress(json, ".reserveAccountBeacon") returns (address instance) {
            _deployment.reserveAccountBeacon = instance;
        } catch {
            console.log("Could not parse reserveAccountBeacon");
        }

        /* Deserialize reserveAccountFactory */
        try vm.parseJsonAddress(json, ".reserveAccountFactory") returns (address instance) {
            _deployment.reserveAccountFactory = instance;
        } catch {
            console.log("Could not parse reserveAccountFactory");
        }
    }
}
