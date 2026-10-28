Pod::Spec.new do |s|
  s.name = 'native_paywall'
  s.version = '1.6.1'
  s.summary = 'Paywall resources, StoreKit environment and product mapping.'
  s.description = 'Provides private offline storage, storefront updates and optional StoreKit price mapping.'
  s.homepage = 'https://github.com/VivaProjects/PaywallKit-flutter'
  s.license = { :type => 'Proprietary' }
  s.author = { 'PaywallKit' => 'support@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'webview_flutter_wkwebview'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
