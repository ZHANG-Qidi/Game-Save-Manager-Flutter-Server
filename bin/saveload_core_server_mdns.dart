import 'dart:convert';
import 'dart:io';
import 'package:mdns_dart/mdns_dart.dart';

Future<bool> isIpReachable(InternetAddress ip) async {
  final isLanIp =
      ip.address.contains(RegExp(r'^192\.168\.(?!137\.|56\.)\d+\.\d+$')) ||
      ip.address.contains(RegExp(r'^10\.\d+\.\d+\.\d+$')) ||
      ip.address.contains(RegExp(r'^172\.(1[6-9]|2\d|3[0-1])\.\d+\.\d+$'));
  if (!isLanIp) return false;
  ServerSocket? serverSocket;
  try {
    serverSocket = await ServerSocket.bind(ip, 9090, shared: true);
    return true;
  } catch (e) {
    if (e.toString().contains('address already in use')) {
      return true;
    }
    return false;
  } finally {
    serverSocket?.close();
  }
}

Future<List<MDNSServer>> startMdnsServer(int port) async {
  print('Starting mDNS server...');
  final interfaces = await NetworkInterface.list();
  List<InternetAddress> localIPs = [];
  final excludeInterfaceNames = ['docker', 'veth', 'vmware', 'hyper-v', 'bluetooth', 'tun', 'tap', 'loopback'];
  for (final interface in interfaces) {
    if (excludeInterfaceNames.any((name) => interface.name.toLowerCase().contains(name))) continue;
    for (final addr in interface.addresses) {
      if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
        if (await isIpReachable(addr)) {
          localIPs.add(addr);
          print('✅ Found valid IP: ${addr.address} (interface: ${interface.name})');
        } else {
          print('❌ Skip unreachable IP: ${addr.address} (interface: ${interface.name})');
        }
      }
    }
  }
  if (localIPs.isEmpty) {
    print('❌ Could not find any valid network interface (IPv4, non-loopback, reachable)');
    return [];
  }
  List<MDNSServer> listMdnsServer = [];
  for (final ip in localIPs) {
    final instanceName = 'Dart Http Server [${ip.address}]';
    try {
      final service = await MDNSService.create(
        instance: instanceName,
        service: '_http._tcp',
        port: port,
        ips: [ip],
        txt: ['jsonrpc=/jsonrpc', 'interface=${ip.address}'],
      );
      final mDnsServer = MDNSServer(MDNSServerConfig(zone: service));
      await mDnsServer.start();
      listMdnsServer.add(mDnsServer);
      print('📌 mDNS Service: $instanceName bound to IP: ${ip.address} (port: ${service.port})');
    } catch (e) {
      print('❌ Failed to create service for ${ip.address}: $e');
    }
  }
  print('✅ All mDNS servers started!');
  return listMdnsServer;
}

Future<List<String>> getLocalIpAddresses() async {
  final interfaces = await NetworkInterface.list();
  List<String> localIps = [];
  for (final interface in interfaces) {
    for (final addr in interface.addresses) {
      if (addr.type == InternetAddressType.IPv4) {
        localIps.add(addr.address);
      }
    }
  }
  return localIps;
}

Future<List<ServiceEntry>> mDnsClient() async {
  // print('\nDiscovering HTTP services...');
  final localIps = await getLocalIpAddresses();
  // print('Local IPs to exclude: ${localIps.join(', ')}\n');
  final results = await MDNSClient.discover('_http._tcp', timeout: Duration(seconds: 3));
  final filteredResults = results.where((service) {
    final serviceIp = service.addrV4?.address;
    return serviceIp == null || !localIps.contains(serviceIp);
  }).toList();
  if (filteredResults.isEmpty) {
    // print('No HTTP services found\n');
    return [];
  } else {
    // print('Found ${filteredResults.length} HTTP service(s):');
    // for (final service in filteredResults) {
    //   print('Service: ${service.name}');
    //   print('  Host: ${service.host}');
    //   print('  IPv4: ${service.addrV4?.address ?? 'none'}');
    //   print('  IPv6: ${service.addrV6?.address ?? 'none'}');
    //   print('  Port: ${service.port}');
    //   print('  Info: ${service.info}');
    //   if (service.infoFields.isNotEmpty) {
    //     print('  TXT: ${service.infoFields.join(', ')}');
    //   }
    //   print('');
    // }
    return filteredResults;
  }
}

Future<List<String>> funcListMdnsServer() async {
  try {
    final listMdnsServer = await mDnsClient();
    if (listMdnsServer.isEmpty) return [];
    return listMdnsServer.map((mDnsServer) {
      final serviceData = {
        'host': mDnsServer.host,
        'ipv4': mDnsServer.addrV4?.address ?? 'none',
        'port': mDnsServer.port,
        'name': mDnsServer.name,
      };
      return jsonEncode(serviceData);
    }).toList();
  } catch (e) {
    throw Exception('Failed to list mDNS Server: $e');
  }
}
