import plistlib,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
objects={}
def add(n, **kw):
 key=f'{n:024X}';objects[key]=kw;return key
src1=add(1,isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='../Widget/AIQuotaWidget.swift',sourceTree='<group>')
src2=add(2,isa='PBXFileReference',lastKnownFileType='sourcecode.swift',path='../Shared/WidgetSnapshot.swift',sourceTree='<group>')
b1=add(3,isa='PBXBuildFile',fileRef=src1);b2=add(4,isa='PBXBuildFile',fileRef=src2)
product=add(5,isa='PBXFileReference',explicitFileType='wrapper.app-extension',path='AIQuotaWidget.appex',sourceTree='BUILT_PRODUCTS_DIR')
products=add(6,isa='PBXGroup',children=[product],name='Products',sourceTree='<group>')
group=add(7,isa='PBXGroup',children=[src1,src2,products],sourceTree='<group>')
sources=add(8,isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[b1,b2],runOnlyForDeploymentPostprocessing=0)
frameworks=add(9,isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[],runOnlyForDeploymentPostprocessing=0)
settings=dict(PRODUCT_NAME='AIQuotaWidget',PRODUCT_BUNDLE_IDENTIFIER='io.github.aiquota.monitor.widget',SWIFT_VERSION='5.0',MACOSX_DEPLOYMENT_TARGET='14.0',SDKROOT='macosx',INFOPLIST_FILE='Info.plist',GENERATE_INFOPLIST_FILE='NO',CODE_SIGNING_ALLOWED='NO',APPLICATION_EXTENSION_API_ONLY='YES',ENABLE_APP_SANDBOX='YES',SKIP_INSTALL='YES',SWIFT_OPTIMIZATION_LEVEL='-O',LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks'])
cfg=add(10,isa='XCBuildConfiguration',name='Release',buildSettings=settings)
configs=add(11,isa='XCConfigurationList',buildConfigurations=[cfg],defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
projcfg=add(12,isa='XCBuildConfiguration',name='Release',buildSettings={})
projconfigs=add(13,isa='XCConfigurationList',buildConfigurations=[projcfg],defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=add(14,isa='PBXNativeTarget',buildConfigurationList=configs,buildPhases=[sources,frameworks],buildRules=[],dependencies=[],name='AIQuotaWidget',productName='AIQuotaWidget',productReference=product,productType='com.apple.product-type.app-extension')
project=add(15,isa='PBXProject',attributes={'LastUpgradeCheck':'2600'},buildConfigurationList=projconfigs,compatibilityVersion='Xcode 14.0',developmentRegion='zh-Hans',knownRegions=['zh-Hans','en'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[target])
(root/'WidgetExtension/AIQuotaWidget.xcodeproj/project.pbxproj').write_bytes(plistlib.dumps(dict(archiveVersion='1',classes={},objectVersion='56',objects=objects,rootObject=project)))
info=dict(CFBundleExecutable='$(EXECUTABLE_NAME)',CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)',CFBundleName='AIQuotaWidget',CFBundleDisplayName='AI额度',CFBundlePackageType='XPC!',CFBundleShortVersionString='1.1.2',CFBundleVersion='5',LSMinimumSystemVersion='$(MACOSX_DEPLOYMENT_TARGET)',AIQuotaAppGroup='$(AI_QUOTA_APP_GROUP)',NSExtension=dict(NSExtensionPointIdentifier='com.apple.widgetkit-extension'))
(root/'WidgetExtension/Info.plist').write_bytes(plistlib.dumps(info))
