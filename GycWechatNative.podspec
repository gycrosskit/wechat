Pod::Spec.new do |s|
  s.name = 'GycWechatNative'
  s.version = '0.1.5'
  s.summary = '微信授权、分享和商家转账确认页 SDK 入口'
  s.homepage = 'https://github.com/gycrosskit/wechat'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'GY CrossKit'
  s.source = { :git => 'https://github.com/gycrosskit/wechat.git', :tag => 'native-0.1.5' }
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'
  s.source_files = 'iosApp/Sources/GycWechatNative/*.swift'
  s.dependency 'WechatOpenSDK-XCFramework', '2.0.7'
end
