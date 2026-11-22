export const studioBundles = {
  ep: { name: 'EP', tracks: 4, sessions: 1, price: 'R1 500', deposit: 'R375' },
  mixtape: { name: 'Mixtape', tracks: 7, sessions: 2, price: 'R2 500', deposit: 'R625' },
  album: { name: 'Album', tracks: 10, sessions: 2, price: 'R4 000', deposit: 'R1 000' }
};

export function bundleSessionLabel(booking) {
  const bundle = studioBundles[booking.bundle_code];
  if (!bundle) return '';
  return `${bundle.name} · session ${booking.bundle_session} of ${bundle.sessions}`;
}
