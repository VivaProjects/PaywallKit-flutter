Pod::Spec.new do |s|
  s.name = 'native_paywall'
  s.version = '0.1.0'
  s.summary = 'Native paywall resource storage.'
  s.description = 'Provides a private persistent directory excluded from backup.'
  s.homepage = 'https://example.invalid/native-paywall'
  s.license = { :type => 'Proprietary' }
  s.author = { 'PaywallKit' => 'support@example.invalid' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
