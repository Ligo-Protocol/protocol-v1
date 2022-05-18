const { expect } = require("chai");
const { ethers } = require("hardhat");
const { secondsSinceEpoch } = require("../../scripts/helper-scripts");

describe("LigoRentalAgreement Unit Test", () => {
  before(async () => {});

  it("Deploys the contract successfully", async () => {
    const [owner, addr1] = await ethers.getSigners();
  });
});
