const nodemailer = require("nodemailer");

const QQtransporter = nodemailer.createTransport({
  service: "QQ",
  auth: {
    user: process.env.EMAIL_QQ_ACCOUNT,
    pass: process.env.EMAIL_QQ_PASSWORD,
  },
});

const Microsofttransporter = nodemailer.createTransport({
  service: "Outlook365",
  host: 'smtp.office365.com',
  port: 587,
  secure: false,
  auth: {
    type: "OAuth2",
    user: "han@rwadealmaker.com",
    clientId: "65274de2-bbaa-4367-add7-03d14bb92fc3",
    tenantId: 'b5cc4c7a-6232-4e5f-9848-9bf017403da2',
    clientSecret: "BQN8Q~-M3Bc54nzkvzJgLtlXp5X-XXXXXXXXXXXXX",
    refreshToken: "1.AUIAekzMtTJiX06YSJvwF0A9ouXXXXXXXXXXXXXXXXXXXXX.AgABAwEAAABlMNzVhAPUTrARzfQjWPtKAwDs_wUA9P8f8JF7H8lMZ_Cmt0FlXqnfoxxx3D0BFyU2cAnuGoHIaSuqiFmwiaZDhI32Ns1FLM0niXotUC7qLEUu4OTG-4qdK1hyAhQq6wUAyoRnei6KLoUdQf03_1OHR5jOgBdltm5Z31dRfPOzmmd-MwT-KihdqCm8Kfqm7LXBX8vo6MOfopSwVUo67ao6u007mozXgc5YcaZYIEuO1XlQYwrEOL7qbCg84vpn-P1Q3cnmouAXvzCnJjLvOuS-fvWdHbs8q52VQHZHrmqrigokOhrt64ydTwvNv7c4sAcDUT9nPijuWBOAgCLWcbNAN6b4o2ZjqCCX3rGbA1WZ8XoIqz2m0wu2_6aOWE1WusiPRB1uInKedxiBZWsL2vueu6ebQAKVqUtB5ySJsxc621EOhwGrnk9hog_nERX74tHJecA9V5A71ygRX39x45Nk2eQ4ELE7URmAp31mK-P0HWX_HWvlrrUwyhVGOcPZAYckv14N5tNb8FTPkd1p_Y_ZaAUNEBdYUkIVSCDtZtlrHtie0oCrdRpfta_P0wiQJBFst2k78JaaLYO6nLk4BK7W94TaGklc2lgqCYhr8loaL6zGnJ15rYlRbI1aD58YwroPtNyKj0FfYODkD5S31kNfEgGOSrf6Xy1z2Wk-azef3JcOCOEhfMEgwmvjTeVF7DGKGh3vJR64kcNyau2raws_X_pZJdOpexzWYXhMQ_gb1GSXNnpdUjHs9CnwRXrSyy9Q4EOreJY4CI_VZscdvYDciCDsHNlRngVbD8j8AwstCVYkreYNN7i1Emm9lZtP1RVdAS6gfud-DNMsur36BcZJMWkB7FYBcHQUhBlVabM_nM1H5EfQHjqVF0gvHm0RG98u7uKvbsyZyX2ncnPlLZ5YKPSvKhckng_2e_CEoMc30y1GCeaH-HNg2Dbj2c3pj0p3aNaWhSi1vlRseQEF_igX7cSNobL_KZyLNAhRMAhCZaAmeSC7mRnqW61os27lkgb9XgDGA4UJ55f9r63GksioYW2yHxFHpNpDPEDJRrpchEzyqzFhgCM7XdO2nZI7tzJd_SE4FIu8AtirZirELlf2NTa8VCh7VG8pHvm57PelcpiPuiNAjAKfo7cQdRfxGUFUWaP0VNsKnhljo_xLkszx3IyH",
  },
  tls: {
    ciphers: 'SSLv3'
  }
});


async function sendVerificationEmail(email, token) {
  const url = `${process.env.FRONTEND_URL}/user/verify-email?token=${token}`;
  await QQtransporter.sendMail({
    from: process.env.EMAIL_ACCOUNT,
    to: email,
    subject: "请验证您的邮箱",
    html: `<p>点击下面的链接完成邮箱验证：</p><a href="${url}">${url}</a>`,
  });
}

async function ContactUs(email) {
  await Microsofttransporter.sendMail({
    from: 'han@rwadealmaker.com',
    to: email,
    subject: "Test Email",
    text: 'This is a test email sent via Office 365 SMTP.'
  });
}

module.exports = { sendVerificationEmail, ContactUs };
