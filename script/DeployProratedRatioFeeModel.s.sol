// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.35;

import "forge-std/Script.sol";

import {ProratedRatioFeeModel} from "src/fees/ProratedRatioFeeModel.sol";

import {Deployer} from "./utils/Deployer.s.sol";

contract DeployProratedRatioFeeModel is Deployer {
    function run() public broadcast useDeployment returns (address) {
        // Deploy ProratedRatioFeeModel
        ProratedRatioFeeModel proratedRatioFeeModel = new ProratedRatioFeeModel();
        console.log("ProratedRatioFeeModel", address(proratedRatioFeeModel));

        _deployment.proratedRatioFeeModel = address(proratedRatioFeeModel);

        return (address(proratedRatioFeeModel));
    }
}
