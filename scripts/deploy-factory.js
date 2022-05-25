const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  const LigoAgreementsFactory = await hre.ethers.getContractFactory(
    "LigoAgreementsFactory"
  );

  const ligoFactory = await LigoAgreementsFactory.deploy();
  await ligoFactory.deployed();

  console.log("Deployed to:", ligoFactory.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
