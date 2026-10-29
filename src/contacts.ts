// Opt-in contact reading for "Find friends from contacts". Only called after the web app's explainer sheet;
// the OS prompt uses NSContactsUsageDescription. Numbers go back to the page, which hashes them (SHA-256 of E.164)
// before anything is uploaded — names and raw numbers never leave the device.
import * as Contacts from 'expo-contacts/legacy';
import { getLocales } from 'expo-localization';

export async function readContactsForPage(): Promise<string> {
  try {
    return await readContactsUnsafe();
  } catch {
    return JSON.stringify({ granted: false });
  }
}

async function readContactsUnsafe(): Promise<string> {
  const perm = await Contacts.requestPermissionsAsync();
  if (perm.status !== 'granted') return JSON.stringify({ granted: false });
  // page through everything (no fixed cap); only name + phone numbers are requested
  const data: Contacts.Contact[] = [];
  for (let pageOffset = 0; pageOffset < 50_000; ) {
    const page = await Contacts.getContactsAsync({ fields: [Contacts.Fields.PhoneNumbers, Contacts.Fields.Name], pageSize: 1000, pageOffset });
    data.push(...page.data);
    if (!page.hasNextPage || !page.data.length) break;
    pageOffset += page.data.length;
  }
  const contacts = data
    .map((c) => ({ name: c.name ?? '', numbers: (c.phoneNumbers ?? []).map((p) => p.number ?? p.digits ?? '').filter(Boolean) }))
    .filter((c) => c.numbers.length);
  const country = (getLocales()[0]?.regionCode ?? 'US').toUpperCase();
  const accessPrivileges = perm.accessPrivileges === 'limited' ? 'limited' : 'all';
  return JSON.stringify({ granted: true, country, contacts, accessPrivileges });
}
