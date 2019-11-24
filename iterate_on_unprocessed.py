import mailbox
import os
import re
import sqlite3

from dateutil.parser import parse

def leaf_payloads_of_mail(m):
  if m.is_multipart():
    ms = [leaf_payloads_of_mail(p) for p in m.get_payload()]
    flattened = [item for sublist in ms for item in sublist]
    return flattened
  else:
    return [(m.get_content_type(), m)]

# returns dict with keys 'text/plain' or 'text/html'
def plaintext_payloads_of_mail(m):
  leaves = leaf_payloads_of_mail(m)
  return dict((ct, m.get_payload(decode=True)) for (ct, m) in leaves if ct.startswith('text'))

# A <B> => B
# <B>   => B
# B     => B
def email_of_from(from_str):
  match = re.search('(.*)<(.*)>', from_str)
  if match:
    return match.group(2)
  else:
    return from_str

def email_of_mail(m):
  return email_of_from(m['From'])

def filename_for_mail(m):
  dt = parse(m['Date'])
  datetime_str = dt.isoformat(timespec='seconds')
  subj = m['Subject']
  name = datetime_str + subj
  return "".join(x if x.isalnum() else "_" for x in name)

def dump_email_payloads(m):
  # output structure
  # dump/<domain>/<friendly>.{txt,html}
  email = email_of_mail(m)
  domain = email.split('@')[1]
  dirname = "dump/%s/" % (domain)
  os.makedirs(dirname, exist_ok = True)

  filename = filename_for_mail(m)
  payloads = plaintext_payloads_of_mail(m)

  if 'text/html' in payloads:
    payload = payloads['text/html']
    f = open(dirname + filename + ".html", "wb")
    f.write(payload)
    f.close()

  if 'text/plain' in payloads:
    payload = payloads['text/plain']
    f = open(dirname + filename + ".txt", "wb")
    f.write(payload)
    f.close()



if __name__ == '__main__':
  print('opening mbox')
  mbox = mailbox.mbox('receipts.mbox')

  print('building list of tuples of emails')
  tuple_of_mail = lambda m: (email_of_from(m['From']), parse(m['Date']), m['Subject'])
  mbox_email_tuples = sorted(tuple_of_mail(m) for m in mbox.itervalues())

  # dict from (email, date, subj) -> Message
  mbox_email_dict = dict((tuple_of_mail(m), m) for m in mbox.itervalues())

  # for (e, d, s) in mbox_email_tuples:
  #   print("email: %s %s %s" % (e, d, s))

  print("%d emails in mbox" % (len(mbox_email_tuples)))

  # load mbox, summarise processed / not.

  print('connecting to DB')
  conn = sqlite3.connect('receipts.db')

  # 'SYNC' EMAILS BETWEEN MBOX AND DB:
  # 1. fetch emails from DB
  c = conn.cursor()
  c.execute('SELECT from_email, date, subject, receipt_id FROM emails')
  rows = c.fetchall()

  print("%d rows loaded from DB" % (len(rows)))

  # dict from (email, date, subj) -> Message
  db_email_dict = dict(((email, parse(date), subject), fk) for (email, date, subject, fk) in rows)

  # Count/WARN about emails in DB that are in DB but not in mbox
  if mbox_email_dict.keys() - db_email_dict.keys() == set():
    print("INFO: all mbox emails are in DB already")
  # XXX: other set comparisons/info

  # Insert all email tuples into DB
  # (DB has UNIQUE constraint on (date, from_email, subject))
  for (email, dt, subj) in mbox_email_tuples:
    domain = email.split('@')[1]
  c.executemany('''
    INSERT OR IGNORE INTO emails (date, from_host, from_email, subject)
    VALUES (?, ?, ?, ?)
  ''', [(dt.isoformat(), email.split('@')[1], email, subj) for (email, dt, subj) in mbox_email_tuples if True])
  conn.commit()

  # TO-PROCESS:
  # - emails which weren't in DB
  # - emails in DB which don't have receipt FK

  # XXX:
  # extract text/html, text/plain from the messages
  #   N.B., some emails have mimetype text/plain, text/html or maybe multipart/mixed
  #     some multipart/mixed have payloads with multipart/alternative,
  #     and so the text/html (or text/plain) is nested (somewhere?) in this.

  # XXX:
  # - dump the payload in a friendly format.
  #   - dump `text/html` part HTML in some dir structure
  #   - dump the text same way;

  # TODO:
  # - try parsing it for each case; input with 'by=parser' or whatever
  #   for successful cases

  # "For the stuff which didn't succeed":

  # - generate SQL INSERT for what it would take to input receipts/items
  #   for a handful of emails (good for "3 emails" or whatever)

  # - go from: smallest (with manual), to largest (which benefit from parser)
  conn.close()