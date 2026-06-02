Name:           gpgui-free
Version:        0.1.0
Release:        1%{?dist}
Summary:        Open-source GTK4 GUI for globalprotect-openconnect

# Zig's default linker omits the GNU build-id note that find-debuginfo
# requires, so skip the debuginfo subpackage entirely.
%global debug_package %{nil}

License:        GPL-3.0-or-later
URL:            https://github.com/MaebashiRamens/gpgui-free
Source0:        https://github.com/MaebashiRamens/%{name}/archive/v%{version}.tar.gz#/%{name}-%{version}.tar.gz

BuildRequires:  zig >= 0.15.2
BuildRequires:  pkgconfig
BuildRequires:  gtk4-devel
BuildRequires:  libadwaita-devel
BuildRequires:  libsecret-devel
BuildRequires:  systemd-rpm-macros

Requires:       globalprotect-openconnect >= 2.5.0
Requires:       glib2
Requires:       gtk4
Requires:       libadwaita
Requires:       libsecret

%description
Drop-in replacement for the proprietary `gpgui` binary that
globalprotect-openconnect downloads from GitHub Releases.
Installs as /usr/bin/gpgui via a symlink and neutralizes
/usr/bin/gpgui-helper so the proprietary binary is never re-fetched.
A systemd path unit re-applies the overlay if upstream package
upgrades remove our symlink.

%prep
%autosetup -n %{name}-%{version}

%build
zig build -Doptimize=ReleaseSafe

%install
install -Dm755 zig-out/bin/gpgui-free %{buildroot}%{_bindir}/gpgui-free
install -Dm755 package/common/install-overlay.sh \
    %{buildroot}%{_prefix}/lib/gpgui-free/install-overlay.sh
install -Dm755 package/common/remove-overlay.sh \
    %{buildroot}%{_prefix}/lib/gpgui-free/remove-overlay.sh
install -Dm755 package/common/restore-overlay.sh \
    %{buildroot}%{_prefix}/lib/gpgui-free/restore-overlay.sh
install -Dm644 package/rhel/gpgui-free-restore.path \
    %{buildroot}%{_unitdir}/gpgui-free-restore.path
install -Dm644 package/rhel/gpgui-free-restore.service \
    %{buildroot}%{_unitdir}/gpgui-free-restore.service

%files
%license LICENSE
%doc README.md
%{_bindir}/gpgui-free
%{_prefix}/lib/gpgui-free/install-overlay.sh
%{_prefix}/lib/gpgui-free/remove-overlay.sh
%{_prefix}/lib/gpgui-free/restore-overlay.sh
%{_unitdir}/gpgui-free-restore.path
%{_unitdir}/gpgui-free-restore.service

%post
%{_prefix}/lib/gpgui-free/install-overlay.sh || :
%systemd_post gpgui-free-restore.path

%preun
if [ $1 -eq 0 ]; then
    %{_prefix}/lib/gpgui-free/remove-overlay.sh || :
fi
%systemd_preun gpgui-free-restore.path

%postun
%systemd_postun_with_restart gpgui-free-restore.path

%changelog
* Tue Jun 02 2026 gpgui-free contributors <noreply@example.com> - 0.1.0-1
- Initial RPM packaging.
