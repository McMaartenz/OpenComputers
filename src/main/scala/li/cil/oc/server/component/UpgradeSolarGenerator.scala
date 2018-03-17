package li.cil.oc.server.component

import java.util

import li.cil.oc.Constants
import li.cil.oc.api.driver.DeviceInfo.DeviceAttribute
import li.cil.oc.api.driver.DeviceInfo.DeviceClass
import li.cil.oc.Settings
import li.cil.oc.api.Network
import li.cil.oc.api.driver.DeviceInfo
import li.cil.oc.api.machine.Arguments
import li.cil.oc.api.machine.Callback
import li.cil.oc.api.machine.Context
import li.cil.oc.api.network.EnvironmentHost
import li.cil.oc.api.network.Visibility
import li.cil.oc.api.prefab
import li.cil.oc.util.BlockPosition
import net.minecraft.world.biome.BiomeGenDesert
import net.minecraftforge.common.util.ForgeDirection

import scala.collection.convert.WrapAsJava._

class UpgradeSolarGenerator(val host: EnvironmentHost) extends prefab.ManagedEnvironment with DeviceInfo {
  override val node = Network.newNode(this, Visibility.Network).
    withComponent("solar", Visibility.Neighbors).
    withConnector().
    create()

  var ticksUntilCheck = 0

  var isSunShining = false

  private final lazy val deviceInfo = Map(
    DeviceAttribute.Class -> DeviceClass.Power,
    DeviceAttribute.Description -> "Solar panel",
    DeviceAttribute.Vendor -> Constants.DeviceInfo.DefaultVendor,
    DeviceAttribute.Product -> "Enligh10"
  )

  override def getDeviceInfo: util.Map[String, String] = deviceInfo

  // ----------------------------------------------------------------------- //

  override val canUpdate = true

  override def update() {
    super.update()

    ticksUntilCheck -= 1
    if (ticksUntilCheck <= 0) {
      ticksUntilCheck = 100
      isSunShining = isSunVisible
    }
    if (isSunShining) {
      node.changeBuffer(Settings.get.solarGeneratorEfficiency)
    }
  }

  private def canSeeSky(): Boolean = {
    val blockPos = BlockPosition(host).offset(ForgeDirection.UP)
    (!host.world.provider.hasNoSky) && host.world.canBlockSeeTheSky(blockPos.x, blockPos.y, blockPos.z)
  }

  private def isSunVisible = {
    val blockPos = BlockPosition(host).offset(ForgeDirection.UP)
    host.world.isDaytime &&
      canSeeSky() &&
      (host.world.getWorldChunkManager.getBiomeGenAt(blockPos.x, blockPos.z).isInstanceOf[BiomeGenDesert] || (!host.world.isRaining && !host.world.isThundering))
  }

  @Callback(doc = """function():boolean -- Returns whether the solar panels have a clear line of sight to the sky.""")
  def canSeeSky(context: Context, args: Arguments): Array[AnyRef] = {
    result(canSeeSky())
  }

  @Callback(doc = """function():boolean -- Returns whether the machine is charging.""")
  def isCharging(context: Context, args: Arguments): Array[AnyRef] = {
    result(isSunShining)
  }
}
