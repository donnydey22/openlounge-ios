// react-native-firebase: SPM + static frameworks collide; opt out of SPM so Firebase comes from CocoaPods.
const { withPodfile } = require('expo/config-plugins');
module.exports = (config) =>
  withPodfile(config, (c) => {
    if (!c.modResults.contents.includes('$RNFirebaseDisableSPM')) {
      c.modResults.contents = '$RNFirebaseDisableSPM = true\n' + c.modResults.contents;
    }
    return c;
  });
