use inc::Module::Install;

name ('Net-Server-Coro');
author ('Alex Vandiver <alexmv@bestpractical.com>');
version_from ('lib/Net/Server/Coro.pm');
abstract_from('lib/Net/Server/Coro.pm');
license('MIT');

requires('Coro');
requires('EV');
requires('Net::Server');

&WriteAll;
