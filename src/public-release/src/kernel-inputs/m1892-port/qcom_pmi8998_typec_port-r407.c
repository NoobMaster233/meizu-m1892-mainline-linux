// SPDX-License-Identifier: GPL-2.0-only
/*
 * PMI8998 hardware-managed CC front-end for qcom_pmic_typec TCPM.
 *
 * The PMI8998 SMB2 USBIN Type-C block lives at 0x1300 and exposes one
 * consolidated type-c-change interrupt.  It performs CC sensing/debounce in
 * hardware, while the separate register-compatible PDPHY at 0x1700 is driven
 * by qcom_pmic_typec_pdphy.c.  This adapter supplies TCPM with the real CC
 * state and preserves the R404 bounded/interlocked VBUS regulator.
 */

#include <linux/bits.h>
#include <linux/interrupt.h>
#include <linux/kernel.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/regulator/consumer.h>
#include <linux/usb/tcpm.h>

#include "qcom_pmic_typec.h"
#include "qcom_pmi8998_typec_port.h"

#define TYPE_C_STATUS_1_REG                    0x0b
#define UFP_TYPEC_RDSTD                        BIT(7)
#define UFP_TYPEC_RD1P5                        BIT(6)
#define UFP_TYPEC_RD3P0                        BIT(5)

#define TYPE_C_STATUS_2_REG                    0x0c
#define DFP_TYPEC_MASK                         GENMASK(3, 0)
#define DFP_RD_OPEN                            BIT(3)
#define DFP_RD_RA_VCONN                        BIT(2)
#define DFP_RD_RD                              BIT(1)
#define DFP_RA_RA                              BIT(0)

#define TYPE_C_STATUS_4_REG                    0x0e
#define UFP_DFP_MODE_STATUS                    BIT(7)
#define TYPEC_VBUS_STATUS                      BIT(6)
#define TYPEC_VBUS_ERROR_STATUS                BIT(5)
#define TYPEC_DEBOUNCE_DONE_STATUS             BIT(4)
#define CC_ORIENTATION                         BIT(1)
#define CC_ATTACHED                            BIT(0)

#define TYPE_C_INTRPT_ENB_REG                  0x67
#define TYPEC_CCOUT_DETACH_INT_EN              BIT(7)
#define TYPEC_CCOUT_ATTACH_INT_EN              BIT(6)
#define TYPEC_VBUS_ERROR_INT_EN                BIT(5)
#define TYPEC_DEBOUNCE_DONE_INT_EN             BIT(3)
#define TYPEC_CCSTATE_CHANGE_INT_EN            BIT(2)
#define TYPEC_VBUS_DEASSERT_INT_EN             BIT(1)
#define TYPEC_VBUS_ASSERT_INT_EN               BIT(0)

#define TYPE_C_INTRPT_ENB_SW_CTRL_REG           0x68
#define TYPEC_VCONN_OVERCURR_INT_EN             BIT(5)
#define VCONN_EN_SRC                            BIT(4)
#define VCONN_EN_VALUE                          BIT(3)
#define TYPEC_POWER_ROLE_CMD_MASK               GENMASK(2, 0)
#define UFP_EN_CMD                              BIT(2)
#define DFP_EN_CMD                              BIT(1)
#define TYPEC_DISABLE_CMD                       BIT(0)

#define TYPEC_IRQ_MASK (TYPEC_CCOUT_DETACH_INT_EN | \
                        TYPEC_CCOUT_ATTACH_INT_EN | \
                        TYPEC_VBUS_ERROR_INT_EN | \
                        TYPEC_DEBOUNCE_DONE_INT_EN | \
                        TYPEC_CCSTATE_CHANGE_INT_EN | \
                        TYPEC_VBUS_DEASSERT_INT_EN | \
                        TYPEC_VBUS_ASSERT_INT_EN)

struct pmi8998_typec_port {
       struct device *dev;
       struct regmap *regmap;
       struct regulator *vbus;
       struct tcpm_port *tcpm_port;
       u32 base;
       int irq;
       bool vbus_enabled;
       struct mutex lock;
};

static int pmi8998_read_status4(struct pmi8998_typec_port *port,
                               unsigned int *status4)
{
       return regmap_read(port->regmap, port->base + TYPE_C_STATUS_4_REG,
                          status4);
}

static bool pmi8998_normal_sink(struct pmi8998_typec_port *port)
{
       unsigned int status2, status4;

       if (regmap_read(port->regmap, port->base + TYPE_C_STATUS_2_REG,
                       &status2) || pmi8998_read_status4(port, &status4))
               return false;

       return (status4 & (CC_ATTACHED | TYPEC_DEBOUNCE_DONE_STATUS |
                          UFP_DFP_MODE_STATUS)) ==
              (CC_ATTACHED | TYPEC_DEBOUNCE_DONE_STATUS |
                          UFP_DFP_MODE_STATUS) &&
              !(status4 & (TYPEC_VBUS_STATUS | TYPEC_VBUS_ERROR_STATUS)) &&
              (status2 & (DFP_RD_OPEN | DFP_RD_RA_VCONN)) &&
              !(status2 & (DFP_RD_RD | DFP_RA_RA));
}

static int pmi8998_get_vbus(struct tcpc_dev *tcpc)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       unsigned int status4;
       int ret;

       mutex_lock(&port->lock);
       ret = pmi8998_read_status4(port, &status4);
       if (!ret)
               ret = port->vbus_enabled || !!(status4 & TYPEC_VBUS_STATUS);
       mutex_unlock(&port->lock);

       return ret;
}

static int pmi8998_set_vbus(struct tcpc_dev *tcpc, bool on, bool sink)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       int ret = 0;

       mutex_lock(&port->lock);
       if (on == port->vbus_enabled)
               goto out;

       if (on) {
               if (!pmi8998_normal_sink(port)) {
                       ret = -EPERM;
                       dev_warn(port->dev,
                                "refused source VBUS without safe normal-sink CC state\n");
                       goto out;
               }
               ret = regulator_enable(port->vbus);
               if (!ret) {
                       port->vbus_enabled = true;
                       dev_info(port->dev,
                                "TCPM enabled bounded 5V/500mA source VBUS\n");
               }
       } else {
               ret = regulator_disable(port->vbus);
               if (!ret) {
                       port->vbus_enabled = false;
                       dev_info(port->dev, "TCPM disabled source VBUS\n");
               }
       }
out:
       mutex_unlock(&port->lock);
       if (!ret && tcpm->tcpm_port)
               tcpm_vbus_change(tcpm->tcpm_port);
       return ret;
}

static int pmi8998_get_cc(struct tcpc_dev *tcpc,
                          enum typec_cc_status *cc1,
                          enum typec_cc_status *cc2)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       enum typec_cc_status active = TYPEC_CC_OPEN;
       unsigned int status, status4;
       bool other_ra = false;
       int ret;

       *cc1 = TYPEC_CC_OPEN;
       *cc2 = TYPEC_CC_OPEN;

       ret = pmi8998_read_status4(port, &status4);
       if (ret)
               return ret;
       if (!(status4 & CC_ATTACHED) ||
           !(status4 & TYPEC_DEBOUNCE_DONE_STATUS))
               return 0;

       if (status4 & UFP_DFP_MODE_STATUS) {
               ret = regmap_read(port->regmap,
                                 port->base + TYPE_C_STATUS_2_REG, &status);
               if (ret)
                       return ret;
               switch (status & DFP_TYPEC_MASK) {
               case DFP_RD_OPEN:
                       active = TYPEC_CC_RD;
                       break;
               case DFP_RD_RA_VCONN:
                       active = TYPEC_CC_RD;
                       other_ra = true;
                       break;
               case DFP_RD_RD:
                       *cc1 = TYPEC_CC_RD;
                       *cc2 = TYPEC_CC_RD;
                       return 0;
               case DFP_RA_RA:
                       *cc1 = TYPEC_CC_RA;
                       *cc2 = TYPEC_CC_RA;
                       return 0;
               default:
                       dev_warn_ratelimited(port->dev,
                                            "unexpected DFP status %#02x\n", status);
                       return 0;
               }
       } else {
               ret = regmap_read(port->regmap,
                                 port->base + TYPE_C_STATUS_1_REG, &status);
               if (ret)
                       return ret;
               if (status & UFP_TYPEC_RD3P0)
                       active = TYPEC_CC_RP_3_0;
               else if (status & UFP_TYPEC_RD1P5)
                       active = TYPEC_CC_RP_1_5;
               else if (status & UFP_TYPEC_RDSTD)
                       active = TYPEC_CC_RP_DEF;
               else
                       return 0;
       }

       if (status4 & CC_ORIENTATION) {
               *cc2 = active;
               if (other_ra)
                       *cc1 = TYPEC_CC_RA;
       } else {
               *cc1 = active;
               if (other_ra)
                       *cc2 = TYPEC_CC_RA;
       }

       return 0;
}

static int pmi8998_set_power_role(struct pmi8998_typec_port *port, u8 role)
{
       return regmap_update_bits(port->regmap,
                                 port->base + TYPE_C_INTRPT_ENB_SW_CTRL_REG,
                                 TYPEC_POWER_ROLE_CMD_MASK, role);
}

static int pmi8998_set_cc(struct tcpc_dev *tcpc, enum typec_cc_status cc)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       u8 role;

       switch (cc) {
       case TYPEC_CC_OPEN:
               role = TYPEC_DISABLE_CMD;
               break;
       case TYPEC_CC_RD:
               role = UFP_EN_CMD;
               break;
       case TYPEC_CC_RP_DEF:
       case TYPEC_CC_RP_1_5:
       case TYPEC_CC_RP_3_0:
               role = DFP_EN_CMD;
               break;
       default:
               return -EINVAL;
       }

       return pmi8998_set_power_role(port, role);
}

static int pmi8998_set_polarity(struct tcpc_dev *tcpc,
                                enum typec_cc_polarity polarity)
{
       return 0;
}

static int pmi8998_set_vconn(struct tcpc_dev *tcpc, bool on)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;

       return regmap_update_bits(port->regmap,
                                 port->base + TYPE_C_INTRPT_ENB_SW_CTRL_REG,
                                 VCONN_EN_SRC | VCONN_EN_VALUE,
                                 VCONN_EN_SRC | (on ? VCONN_EN_VALUE : 0));
}

static int pmi8998_start_toggling(struct tcpc_dev *tcpc,
                                  enum typec_port_type port_type,
                                  enum typec_cc_status cc)
{
       struct pmic_typec *tcpm = tcpc_to_tcpm(tcpc);
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       u8 role;

       switch (port_type) {
       case TYPEC_PORT_SRC:
               role = DFP_EN_CMD;
               break;
       case TYPEC_PORT_SNK:
               role = UFP_EN_CMD;
               break;
       case TYPEC_PORT_DRP:
               role = 0;
               break;
       default:
               return -EINVAL;
       }

       return pmi8998_set_power_role(port, role);
}

static irqreturn_t pmi8998_typec_irq(int irq, void *data)
{
       struct pmi8998_typec_port *port = data;

       tcpm_cc_change(port->tcpm_port);
       tcpm_vbus_change(port->tcpm_port);
       return IRQ_HANDLED;
}

static int pmi8998_port_start(struct pmic_typec *tcpm,
                              struct tcpm_port *tcpm_port)
{
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;
       int ret;

       port->tcpm_port = tcpm_port;
       ret = regmap_write(port->regmap,
                          port->base + TYPE_C_INTRPT_ENB_REG,
                          TYPEC_IRQ_MASK);
       if (ret)
               return ret;

       enable_irq(port->irq);
       tcpm_cc_change(tcpm_port);
       tcpm_vbus_change(tcpm_port);
       dev_info(port->dev,
                "PMI8998 hardware CC attached to TCPM with consolidated IRQ\n");
       return 0;
}

static void pmi8998_port_stop(struct pmic_typec *tcpm)
{
       struct pmi8998_typec_port *port =
               (struct pmi8998_typec_port *)tcpm->pmic_typec_port;

       disable_irq(port->irq);
       mutex_lock(&port->lock);
       if (port->vbus_enabled) {
               regulator_disable(port->vbus);
               port->vbus_enabled = false;
       }
       mutex_unlock(&port->lock);
       pmi8998_set_power_role(port, 0);
}

int qcom_pmi8998_typec_port_probe(struct platform_device *pdev,
                                  struct pmic_typec *tcpm,
                                  struct regmap *regmap, u32 base)
{
       struct device *dev = &pdev->dev;
       struct pmi8998_typec_port *port;
       int ret;

       port = devm_kzalloc(dev, sizeof(*port), GFP_KERNEL);
       if (!port)
               return -ENOMEM;

       port->dev = dev;
       port->regmap = regmap;
       port->base = base;
       mutex_init(&port->lock);

       port->vbus = devm_regulator_get(dev, "vdd-vbus");
       if (IS_ERR(port->vbus))
               return dev_err_probe(dev, PTR_ERR(port->vbus),
                                    "failed to acquire bounded VBUS\n");

       port->irq = platform_get_irq_byname(pdev, "type-c-change");
       if (port->irq < 0)
               return port->irq;

       ret = devm_request_threaded_irq(dev, port->irq, NULL,
                                       pmi8998_typec_irq,
                                       IRQF_ONESHOT | IRQF_NO_AUTOEN,
                                       "type-c-change", port);
       if (ret)
               return ret;

       tcpm->pmic_typec_port = (struct pmic_typec_port *)port;
       tcpm->tcpc.get_vbus = pmi8998_get_vbus;
       tcpm->tcpc.set_vbus = pmi8998_set_vbus;
       tcpm->tcpc.get_cc = pmi8998_get_cc;
       tcpm->tcpc.set_cc = pmi8998_set_cc;
       tcpm->tcpc.set_polarity = pmi8998_set_polarity;
       tcpm->tcpc.set_vconn = pmi8998_set_vconn;
       tcpm->tcpc.start_toggling = pmi8998_start_toggling;
       tcpm->port_start = pmi8998_port_start;
       tcpm->port_stop = pmi8998_port_stop;

       return 0;
}
