const hre = require("hardhat");
const [contractArgs] = require("./arguments");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  const LigoRentalAgreement = await hre.ethers.getContractFactory(
    "LigoRentalAgreement"
  );
  const ligoAgreement = await LigoRentalAgreement.deploy(contractArgs, {
    value: ethers.utils.parseEther("0.02"),
  });
  await ligoAgreement.deployed();
  console.log("Deployed to:", ligoAgreement.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
