const secondsSinceEpoch = () => {
  return Math.round(Date.now() / 1000);
};

module.exports = { secondsSinceEpoch };
