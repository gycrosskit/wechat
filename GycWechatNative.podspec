Pod::Spec.new do |s|
  s.name = 'GycWechatNative'
  s.version = '0.1.7'
  s.summary = '微信授权、分享和商家转账确认页 SDK 入口'
  s.homepage = 'https://github.com/gycrosskit/wechat'
  s.license = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author = 'GY CrossKit'
  s.source = { :git => 'https://github.com/gycrosskit/wechat.git', :tag => 'native-0.1.7' }
  s.ios.deployment_target = '15.0'
  s.swift_version = '5.9'
  # 厂商 XCFramework 含静态库，组件不能作为动态 framework 传递链接它们。
  s.static_framework = true
  s.default_subspec = 'Native'
  s.subspec 'Native' do |native|
    native.source_files = 'iosApp/Sources/GycWechatNative/*.swift'
    native.dependency 'WechatOpenSDK-XCFramework', '2.0.7'
  end
  s.subspec 'Kuikly' do |kuikly|
    kuikly.dependency 'GycWechatNative/Native'
    kuikly.dependency 'OpenKuiklyIOSRender', '2.28.0'
    kuikly.source_files = 'iosApp/Sources/GycWechatKuikly/*.swift'
  end
end
